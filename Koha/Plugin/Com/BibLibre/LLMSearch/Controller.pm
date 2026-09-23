package Koha::Plugin::Com::BibLibre::LLMSearch::Controller;

use Modern::Perl;
use Mojo::Base 'Mojolicious::Controller';
use Koha::Plugin::Com::BibLibre::LLMSearch;
use Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Chat;

our $plugin = Koha::Plugin::Com::BibLibre::LLMSearch->new();

sub welcome {
    my $c = shift->openapi->valid_input or return;
    my $welcome_msg = $plugin->retrieve_data('welcome');
    utf8::encode($welcome_msg) if defined $welcome_msg;
    return $c->render(
        status  => 200,
        openapi => $welcome_msg,
        charset => 'UTF-8'
    );
}

sub chat {
    my $c = shift;
    return Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Chat::handle_chat_request($c, $plugin);
}



1;
