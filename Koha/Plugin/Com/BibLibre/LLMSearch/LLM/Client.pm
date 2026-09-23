package Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Client;

use Modern::Perl;
use LWP::UserAgent;
use HTTP::Request;
use JSON qw(encode_json);

=head1 NAME

Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Client - LLM API communication

=head1 DESCRIPTION

This module handles HTTP communication with the LLM API (Mistral, OpenAI, etc.).

=head1 FUNCTIONS

=head2 call

Sends a request to the LLM API and returns the HTTP::Response object.

=cut

sub call {
    my ( $ua, $base_url, $api_key, $payload ) = @_;
    my $header = [
        'Content-Type'  => 'application/json',
        'Accept'        => 'application/json',
        'Authorization' => 'Bearer ' . $api_key,
    ];
    my $req = HTTP::Request->new( 'POST', $base_url, $header, encode_json($payload) );
    return $ua->request($req);
}

1;
