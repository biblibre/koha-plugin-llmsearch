package Koha::Plugin::Com::BibLibre::LLMSearch::Search::Tools;

use Modern::Perl;
use C4::Context;

=head1 NAME

Koha::Plugin::Com::BibLibre::LLMSearch::Search::Tools - LLM tool definitions and execution

=head1 DESCRIPTION

This module provides the tool definitions for the LLM assistant and
executes catalog searches and authority lookups.

=head1 FUNCTIONS

=head2 get_search_tools

Returns the OpenAI-compatible tool definition for search_catalog,
with parameters built dynamically from Koha's live search field list.

=cut

sub get_search_tools {
    my $fields = Koha::Plugin::Com::BibLibre::LLMSearch::Search::Fields::get_opac_biblio_search_fields();

    my %properties;
    for my $field (@$fields) {
        my $desc = $field->{label};
        # For date fields, add CCL date-range syntax instructions
        if ( $field->{name} =~ /date/i ) {
            $desc .= '. Use CCL date range syntax (no quotes, no < or > signs): '
                   . 'exact year -> "2005"; '
                   . 'range -> "2005-2014"; '
                   . 'before 2005 (i.e. up to 2004) -> "-2004"; '
                   . 'from 2005 onwards -> "2005-".';
        }
        # Flag fields backed by authorized values
        if ( Koha::Plugin::Com::BibLibre::LLMSearch::Search::Fields::get_field_av_category( $field->{name} ) ) {
            $desc .= ' [controlled vocabulary -- call get_authorized_values("'
                   . $field->{name}
                   . '") to get the list of valid values before searching]';
        }
        $properties{ $field->{name} } = {
            type        => 'string',
            description => $desc,
        };
    }

    # Safety net: if no fields are configured yet, expose a generic keyword param
    unless (%properties) {
        %properties = (
            keyword => { type => 'string', description => 'General keyword search' },
        );
    }

    return [
        {
            type     => 'function',
            function => {
                name        => 'search_catalog',
                description =>
                    'Search the library catalog and return the number of matching results. '
                    . 'Call this tool to verify that a search will return results BEFORE including a link in your response. '
                    . 'If the count is 0, adjust the criteria (broader terms, fewer constraints, synonyms) and try again.',
                parameters => {
                    type       => 'object',
                    properties => \%properties,
                    required   => [],
                },
            },
        },
        {
            type     => 'function',
            function => {
                name        => 'get_authorized_values',
                description =>
                    'Get the list of valid controlled-vocabulary values for a search field. '
                    . 'Call this when a field description says "[controlled vocabulary]" '
                    . 'to retrieve the exact values you should use in your query.',
                parameters => {
                    type       => 'object',
                    properties => {
                        field_name => {
                            type        => 'string',
                            description => 'The search field name to look up (e.g. "subject", "language")',
                        },
                    },
                    required => ['field_name'],
                },
            },
        },
        {
            type     => 'function',
            function => {
                name        => 'get_authority',
                description =>
                    'Check if an authority exists using Koha\'s authority search system. '
                    . 'Call this when a field description says "[authority field]" '
                    . 'to verify that the authority value exists before searching. '
                    . 'Returns: exists (bool), authid, count, and heading if found.',
                parameters => {
                    type       => 'object',
                    properties => {
                        field_name => {
                            type        => 'string',
                            description => 'The search field name (e.g. "author", "subject")',
                        },
                        value => {
                            type        => 'string',
                            description => 'The authority value to check',
                        },
                    },
                    required => ['field_name', 'value'],
                },
            },
        },
    ];
}

=head2 execute_search

Runs a live Koha catalog search and returns the result count.

=cut

sub execute_search {
    my ($params) = @_;

    require Koha::SearchEngine::Search;
    require Koha::SearchEngine;

    my $searcher = Koha::SearchEngine::Search->new(
        { index => $Koha::SearchEngine::BIBLIOS_INDEX }
    );

    my $query = Koha::Plugin::Com::BibLibre::LLMSearch::Search::CCL::build_query($params);
    my ( $error, $marcresults, $total_hits ) =
        $searcher->simple_search_compat( $query, 0, 1 );

    if ($error) {
        warn "LLMSearch: search error for query '$query': $error";
        return { count => 0, query => $query, error => "$error" };
    }

    return { count => ( $total_hits // 0 ), query => $query };
}

=head2 execute_get_authorized_values

Returns the list of valid authorized values for a given search field.

=cut

sub execute_get_authorized_values {
    my ($params) = @_;

    my $field_name = $params->{field_name};
    return { error => 'field_name parameter is required' }
        unless $field_name;

    my $category = Koha::Plugin::Com::BibLibre::LLMSearch::Search::Fields::get_field_av_category($field_name);
    return { message => "Field '$field_name' does not use controlled vocabulary" }
        unless $category;

    my $dbh = C4::Context->dbh;
    my $sth = $dbh->prepare( q{
        SELECT authorised_value, lib
        FROM   authorised_values
        WHERE  category = ?
        ORDER  BY lib
    } );
    $sth->execute($category);

    my @values;
    while ( my ( $av, $lib ) = $sth->fetchrow_array ) {
        push @values, { value => $av, label => ( $lib // $av ) };
    }

    return { category => $category, values => \@values };
}

=head2 execute_get_authority

Checks if an authority exists in the database for a given search field.
Uses Koha::SearchEngine::Search->search_auth_compat for proper authority search.

=cut

sub execute_get_authority {
    my ($params) = @_;

    my $field_name = $params->{field_name};
    my $value      = $params->{value};

    return { error => 'field_name parameter is required' }
        unless $field_name;
    return { error => 'value parameter is required' }
        unless defined $value && $value ne '';

    # Use Koha::SearchEngine::Search->search_auth_compat for proper authority search
    # search_auth_compat uses C4::AuthoritiesMarc::SearchAuthorities internally
    eval {
        require Koha::SearchEngine::Search;
        
        my $searcher = Koha::SearchEngine::Search->new;
        
        # Build query parameters for search_auth_compat
        # It expects: marclist, and_or, excluding, operator, value, authtypecode, orderby
        my $query_params = { value => [$value] };
        my ( $error, $results, $total_hits ) =
            $searcher->search_auth_compat( $query_params, 0, 1, 1 );

        if ($error) {
            warn "LLMSearch: Authority search error: $error";
            return { exists => 0, count => 0, error => $error };
        }

        if ($results && ref $results eq 'ARRAY' && @$results) {
            # Return first match information
            my $first = $results->[0];
            return {
                exists  => 1,
                authid  => $first->{authid},
                count   => scalar(@$results),
                heading => $first->{heading},
            };
        }
        else {
            return { exists => 0, count => 0 };
        }
    };
}

1;
