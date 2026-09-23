package Koha::Plugin::Com::BibLibre::LLMSearch::Search::CCL;

use Modern::Perl;

=head1 NAME

Koha::Plugin::Com::BibLibre::LLMSearch::Search::CCL - CCL (Common Command Language) query building utilities

=head1 DESCRIPTION

This module provides utilities for building CCL (Common Command Language) queries
for Koha catalog searches.

=head1 FUNCTIONS

=head2 escape_value

Wraps a value in double quotes for CCL phrase search and removes any
embedded quotes to prevent query injection.

=cut

sub escape_value {
    my ($val) = @_;
    $val =~ s/"//g;
    return qq("$val");
}

=head2 is_date_range

Returns true if the value looks like a CCL date range expression that
must NOT be quoted: e.g. "2005", "-2004", "2005-2014", "2005-"

=cut

sub is_date_range {
    my ($val) = @_;
    return $val =~ /^-?\d{4}(-\d{4})?$|^\d{4}-$/;
}

=head2 build_query

Converts structured search parameters into a CCL query string.
Iterates over whatever field names the LLM provided (which are the live
Koha search_field names) and builds fieldname:"value" expressions.
Date range values (e.g. -2004, 2005-2014, 2005) are passed unquoted.

=cut

sub build_query {
    my ($params) = @_;
    my @parts;

    for my $field_name ( sort keys %$params ) {
        my $val = $params->{$field_name};
        next unless defined $val && $val ne '';
        my $ccl_val = is_date_range($val) ? $val : escape_value($val);
        push @parts, $field_name . ':' . $ccl_val;
    }

    return @parts ? join( ' AND ', @parts ) : 'kw:*';
}

1;
