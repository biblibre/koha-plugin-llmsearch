package Koha::Plugin::Com::BibLibre::LLMSearch::Search;

use Modern::Perl;
use C4::Context;

=head1 NAME

Koha::Plugin::Com::BibLibre::LLMSearch::Search - Catalog search field and CCL query utilities

=head1 DESCRIPTION

This module provides utilities for working with Koha search fields and for
building CCL (Common Command Language) queries for Koha catalog searches.

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
        # Skip whitespace-only values
        next if $val =~ /^\s*$/;
        my $ccl_val = is_date_range($val) ? $val : escape_value($val);
        push @parts, $field_name . ':' . $ccl_val;
    }

    return @parts ? join( ' AND ', @parts ) : 'kw:*';
}

=head2 get_opac_biblio_search_fields

Returns all search fields from Koha's search_field table that are
enabled for the OPAC and mapped to the biblios index.

=cut

sub get_opac_biblio_search_fields {
    require Koha::SearchFields;

    my @fields;
    my $all = Koha::SearchFields->search( { opac => 1 }, { order_by => 'label' } );
    while ( my $field = $all->next ) {
        push @fields, { name => $field->name, label => $field->label }
            if $field->is_mapped_biblios;
    }
    return \@fields;
}

=head2 get_field_av_category

Traces search_field -> search_marc_to_field -> search_marc_map ->
marc_subfield_structure to find whether the field is backed by an
authorized value category. Returns the category name or undef.

=cut

sub get_field_av_category {
    my ($field_name) = @_;

    my $dbh       = C4::Context->dbh;
    my $marc_type = lc( C4::Context->preference('marcflavour') );

    return $field_name
	if ( grep(/$field_name/, ('itemtype', 'itype', 'holdingbranch', 'homebranch') ) );

    # marc_field is stored as e.g. "245a" or "245$a"; handle both formats.
    # Filter by marc_type so UNIMARC instances don't match MARC21 mappings
    # (and vice-versa).
    my $sth = $dbh->prepare( q{
        SELECT DISTINCT mss.authorised_value
        FROM   search_field sf
        JOIN   search_marc_to_field smtf ON smtf.search_field_id = sf.id
        JOIN   search_marc_map      smm  ON smm.id = smtf.search_marc_map_id
        JOIN   marc_subfield_structure mss
               ON  mss.tagfield    = SUBSTRING(smm.marc_field, 1, 3)
               AND mss.tagsubfield = REPLACE(SUBSTRING(smm.marc_field, 4), '$', '')
        WHERE  sf.name              = ?
          AND  smm.index_name       = 'biblios'
          AND  smm.marc_type        = ?
          AND  mss.authorised_value IS NOT NULL
          AND  mss.authorised_value != ''
        LIMIT 1
    } );
    $sth->execute($field_name, $marc_type);
    my ($category) = $sth->fetchrow_array;
    return $category;
}

1;
