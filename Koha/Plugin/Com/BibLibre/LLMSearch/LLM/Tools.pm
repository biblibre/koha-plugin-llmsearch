package Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Tools;

use Modern::Perl;
use C4::Context;
use Koha::Plugin::Com::BibLibre::LLMSearch::Search;

=head1 NAME

Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Tools - LLM tool definitions and execution

=head1 DESCRIPTION

This module provides the tool definitions for the LLM assistant and
executes catalog searches and authority lookups.

=head1 FUNCTIONS

=head2 get_search_tools

Returns the OpenAI-compatible tool definition for search_catalog,
with parameters built dynamically from Koha's live search field list.

=cut

sub get_search_tools {
    # Note: We no longer include field definitions here to avoid sending
    # the full field list with every LLM call. Instead, the LLM should use
    # the get_search_indexes tool to discover available fields.
    
    return [
        {
            type     => 'function',
            function => {
                name        => 'search_catalog',
                description =>
                    'Search the catalog and return the number of matching results. '
                    . 'Parameters are search field/value pairs (e.g. {"subject": "science fiction"}); '
                    . 'use field names from the get_search_indexes tool. '
                    . 'If the count is 0, broaden the criteria and try again. '
                    . 'Always call this tool before giving the user a search link.',
                parameters => {
                    type       => 'object',
                    properties => {},
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
                name        => 'get_item_types',
                description =>
                    'Get the available document/item type codes with their descriptions. '
                    . 'Call this when the user asks for a medium or type (music, film, audiobook...) '
                    . 'and use a returned code as the itemtype value in search_catalog.',
                parameters => {
                    type       => 'object',
                    properties => {},
                    required   => [],
                },
            },
        },
        {
            type     => 'function',
            function => {
                name        => 'get_authority',
                description =>
                    'Check that an authority (author, subject heading, series...) exists in the library authority records. '
                    . 'Returns: exists (bool), authid, count, and heading (standardized display form) if found. '
                    . 'Optional: call before searching to validate a name and prefer the returned heading.',
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
        {
            type     => 'function',
            function => {
                name        => 'get_search_indexes',
                description =>
                    'Get the list of available search fields (name and label) for the catalog. '
                    . 'Call this tool FIRST: search_catalog only accepts field names from this list.',
                parameters => {
                    type       => 'object',
                    properties => {},
                    required   => [],
                },
            },
        },
    ];
}

=head2 search_catalog

Runs a live Koha catalog search and returns the result count.

=cut

sub search_catalog {
    my ($self, $params) = @_;

    require Koha::SearchEngine::Search;
    require Koha::SearchEngine;

    my $searcher = Koha::SearchEngine::Search->new(
        { index => $Koha::SearchEngine::BIBLIOS_INDEX }
    );

    my $query = Koha::Plugin::Com::BibLibre::LLMSearch::Search::build_query($params);
    my ( $error, $marcresults, $total_hits ) =
        $searcher->simple_search_compat( $query, 0, 1 );

    if ($error) {
        return { count => 0, query => $query, error => "$error" };
    }

    return { count => ( $total_hits // 0 ), query => $query };
}

=head2 get_authorized_values

Returns the list of valid authorized values for a given search field.
For itemtype/itype fields, returns document types from Koha::ItemTypes.
For holdingbranch and homebranch fields, returns library branches from Koha::Libraries.
For other fields with controlled vocabulary, returns values from authorised_values.

=cut

sub get_authorized_values {
    my ($self, $params) = @_;

    my $field_name = $params->{field_name};
    return { error => 'field_name parameter is required' }
        unless $field_name;

    # Special handling for itemtype/itype fields
    if ( $field_name eq 'itemtype' || $field_name eq 'itype' ) {
        my $item_types = Koha::ItemTypes->search_with_localization;
        my @values;
        while ( my $item_type = $item_types->next ) {
            push @values, {
                value => $item_type->itemtype,
                label => $item_type->translated_description,
            };
        }
        return { field_type => 'itemtype', values => \@values };
    }

    # Special handling for holdingbranch and homebranch fields
    if ( $field_name eq 'holdingbranch' || $field_name eq 'homebranch' ) {
        my $libraries = Koha::Libraries->search( {}, { order_by => 'branchname' } );
        my @values;
        while ( my $library = $libraries->next ) {
            push @values, {
                value => $library->branchcode,
                label => $library->branchname,
            };
        }
        return { field_type => $field_name, values => \@values };
    }

    # Default handling for authorized values
    my $category = Koha::Plugin::Com::BibLibre::LLMSearch::Search::get_field_av_category($field_name);
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

=head2 get_search_indexes

Returns the list of available search indexes for the catalog.
This is a lightweight tool that returns just the field names and labels,
without consuming tokens in the system prompt.

=cut

sub get_search_indexes {
    my $fields = Koha::Plugin::Com::BibLibre::LLMSearch::Search::get_opac_biblio_search_fields();

    my @indexes;
    for my $field (@$fields) {
        my $desc = $field->{label};
        
        # Add CCL date-range syntax instructions for date fields
        if ( $field->{name} =~ /date/i ) {
            $desc .= '. Use CCL date range syntax (no quotes, no < or > signs): '
                   . 'exact year -> "2005"; '
                   . 'range -> "2005-2014"; '
                   . 'before 2005 (i.e. up to 2004) -> "-2004"; '
                   . 'from 2005 onwards -> "2005-".';
        }
        
        # Flag fields backed by authorized values
        if ( my $category = Koha::Plugin::Com::BibLibre::LLMSearch::Search::get_field_av_category( $field->{name} ) ) {
            $desc .= ' [controlled vocabulary -- call get_authorized_values("'
                   . $field->{name}
                   . '") to get the list of valid values before searching]';
        }
        
        push @indexes, {
            name => $field->{name},
            label => $field->{label},
            description => $desc,
        };
    }

    return { indexes => \@indexes };
}

=head2 get_item_types

Returns the list of available document/item types from Koha.
These are the valid values for the 'itype' field in catalog searches.

=cut

sub get_item_types {
    # Use Koha::ItemTypes to get all document types with localization
    my $item_types = Koha::ItemTypes->search_with_localization;

    my @types;
    while ( my $item_type = $item_types->next ) {
        push @types, {
            itemtype => $item_type->itemtype,
            description => $item_type->translated_description,
            imageurl => $item_type->imageurl,
        };
    }

    return { item_types => \@types };
}

=head2 get_authority

Checks if an authority exists in the database for a given search field.
Uses Koha::SearchEngine::Search->search_auth_compat for proper authority search.

=cut

sub get_authority {
    my ($self, $params) = @_;

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
