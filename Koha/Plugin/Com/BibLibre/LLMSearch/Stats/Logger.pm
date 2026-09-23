package Koha::Plugin::Com::BibLibre::LLMSearch::Stats::Logger;

use Modern::Perl;
use C4::Context;
use Koha::DateUtils qw(dt_from_string);
use Koha::Plugin::Com::BibLibre::LLMSearch;

=head1 NAME

Koha::Plugin::Com::BibLibre::LLMSearch::Stats::Logger - Request logging and statistics

=head1 DESCRIPTION

This module handles logging of LLM requests to the statistics table.

=head1 FUNCTIONS

=head2 log_request

Logs a request to the statistics table when enable_stats is configured.
Handles both authenticated and unauthenticated (OPAC without login) requests.

=cut

sub log_request {
    my $args      = shift;
    my $opac_lang = $args->{'lang'};
    my $response  = $args->{'data'};

    my $plugin = Koha::Plugin::Com::BibLibre::LLMSearch->new();
    return 1 unless ( $plugin->retrieve_data('enable_stats') );

    my $dbh   = C4::Context->dbh;
    my $table = $plugin->get_qualified_table_name('stats');

    my $userenv = C4::Context->userenv;
    my $patron;
    if ($userenv && ref($userenv) eq 'HASH' && $userenv->{'number'}) {
        $patron = Koha::Patrons->find( $userenv->{'number'} );
        $patron = $patron->unblessed() if $patron;
    }

    my $prompt_tokens = $response ? ($response->{usage}{prompt_tokens} // 0) : 0;
    my $completion_tokens = $response ? ($response->{usage}{completion_tokens} // 0) : 0;

    my $query = "INSERT INTO $table (
                     opac_lang,
                     tokens_sent,
                     tokens_received
                 ) VALUES (
                     " . $dbh->quote($opac_lang) . ",
                     $prompt_tokens,
                     $completion_tokens
                 )";

    return $dbh->do($query) unless $patron;

    my $enrolledyear = dt_from_string( $patron->{dateenrolled}, undef, undef )->year;
    my $birthyear    = dt_from_string( $patron->{dateofbirth},  undef, undef )->year;
    $query = "
        INSERT INTO $table (
            categorycode,
            branchcode,
            enrolled_year,
            birth_year,
            sort1,
            sort2,
            opac_lang,
            tokens_sent,
            tokens_received
        ) VALUES (
            " . $dbh->quote($patron->{categorycode} // '') . ",
            " . $dbh->quote($patron->{branchcode} // '') . ",
            " . $dbh->quote($enrolledyear) . ",
            " . $dbh->quote($birthyear) . ",
            " . $dbh->quote($patron->{sort1} // '') . ",
            " . $dbh->quote($patron->{sort2} // '') . ",
            " . $dbh->quote($opac_lang) . ",
            $prompt_tokens,
            $completion_tokens
        )";

    return $dbh->do($query);
}

1;
