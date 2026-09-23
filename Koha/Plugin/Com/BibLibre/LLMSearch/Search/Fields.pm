package Koha::Plugin::Com::BibLibre::LLMSearch::Search::Fields;

use Modern::Perl;
use C4::Context;

=head1 NAME

Koha::Plugin::Com::BibLibre::LLMSearch::Search::Fields - Search field utilities

=head1 DESCRIPTION

This module provides utilities for working with Koha search fields.

=head1 FUNCTIONS

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

=head2 build_index_list_text

Builds a human-readable index list from live Koha search fields,
for injection into the system prompt via the {{SEARCH_INDEXES}} placeholder.

=cut

sub build_index_list_text {
    my $fields = get_opac_biblio_search_fields();

    unless (@$fields) {
        return 'No search indexes are currently configured for the OPAC in this Koha instance.';
    }

    my @lines = (
        'Here are the available search field names '
        . '(use as CCL prefix in queries, e.g. author:"tolkien"):',
    );
    for my $f (@$fields) {
        push @lines, sprintf( '- %s: %s', $f->{name}, $f->{label} );
    }
    return join( "\n", @lines );
}

1;
