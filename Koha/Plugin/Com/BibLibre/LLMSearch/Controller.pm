package Koha::Plugin::Com::BibLibre::LLMSearch::Controller;

use Modern::Perl;
use C4::Context;
use C4::Auth qw( get_session );
use Koha::Plugin::Com::BibLibre::LLMSearch;
use Koha::Patron;
use Koha::DateUtils qw( dt_from_string );
use Mojo::Base 'Mojolicious::Controller';
use URI::Escape;
use Encode qw(encode);
use JSON qw( encode_json decode_json );
use LWP::UserAgent;
use HTTP::Request;
use HTTP::Response;

# Import specialized modules
use Koha::Plugin::Com::BibLibre::LLMSearch::Search::CCL;
use Koha::Plugin::Com::BibLibre::LLMSearch::Search::Fields;
use Koha::Plugin::Com::BibLibre::LLMSearch::Search::Tools;
use Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Client;
use Koha::Plugin::Com::BibLibre::LLMSearch::Stats::Logger;

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
    my $cookies = $c->req->cookies;

    my $session;
    my $opac_lang;
    foreach my $cookie (@$cookies) {
        if ( $cookie->{name} eq 'CGISESSID' ) {
            $session = get_session( $cookie->{value} );
        }
        if ( $cookie->{name} eq 'KohaOpacLanguage' ) {
            $opac_lang = $cookie->{value};
        }
    }

    return $c->render(
        status  => 500,
        openapi => { error => "missing authorization from UI" }
    ) if $session->is_new();

    $c = $c->openapi->valid_input or return;

    my $api_key  = $plugin->retrieve_data('api_key');
    my $base_url = $plugin->retrieve_data('base_url');
    my $model    = $plugin->retrieve_data('model');
    my $prompt   = $plugin->retrieve_data('system_prompt') || $plugin->mbf_read('system_prompt.txt');
    # Inject the live index list from Koha's search_field table
    $prompt =~ s/\{\{SEARCH_INDEXES\}\}/Koha::Plugin::Com::BibLibre::LLMSearch::Search::Fields::build_index_list_text()/e;
    my $max_tool_rounds = $plugin->retrieve_data('max_tool_rounds') // 5;
    $max_tool_rounds = 1 if $max_tool_rounds < 1;

    return $c->render(
        status  => 500,
        openapi => { error => "missing configuration" }
    ) unless $base_url and $model;

    my $user_agent = LWP::UserAgent->new;
    $user_agent->agent("KohaLLMSearch");

    my $json = $c->validation->param('json');
    $json = uri_unescape($json);
    my $previous_chat;
    if ( $json =~ /json=(.*)/ ) {
        $previous_chat = decode_json($1);
    }

    my @messages = ( { "role" => "system", "content" => $prompt } );

    foreach my $message (@$previous_chat) {
        $message->{content} =~ s/\+/ /g;
        push @messages, $message;
    }

    # -------------------------------------------------------------------------
    # Agentic tool-call loop
    # -------------------------------------------------------------------------
    my $tools          = Koha::Plugin::Com::BibLibre::LLMSearch::Search::Tools::get_search_tools();
    my $final_response;
    my $debug_mode     = $plugin->retrieve_data('debug_mode') // 0;
    my @debug_log;      # collected only when debug_mode is on
    # Pre-serialise debug entries to strings so Mojo::JSON never has to
    # traverse the (potentially very deep) combined structure.
    my $debug_json = $debug_mode ? JSON->new->utf8->max_depth(2048) : undef;

    for my $round ( 1 .. $max_tool_rounds ) {
        my $chat_payload = { model => $model, messages => [@messages], tools => $tools };

        if ( $debug_mode ) {
            eval { push @debug_log, $debug_json->encode({ round => $round, request => $chat_payload }) };
            warn "LLMSearch debug encode error (request): $@" if $@;
        }

        my $http_response = Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Client::call( $user_agent, $base_url, $api_key, $chat_payload );

        unless ( $http_response->is_success ) {
            return $c->render(
                status  => 500,
                openapi => { error => $http_response->decoded_content }
            );
        }

        my $content = $http_response->decoded_content;
        my $response_data = decode_json($content);
        my $choice        = $response_data->{choices}[0];

        if ( $debug_mode ) {
            eval { push @debug_log, $debug_json->encode({ round => $round, response => $response_data }) };
            warn "LLMSearch debug encode error (response): $@" if $@;
        }

        # If the LLM wants to call tools, execute them and loop
        if ( $choice->{finish_reason} && $choice->{finish_reason} eq 'tool_calls' )
        {
            # Append the assistant's tool_calls message to the history
            push @messages, $choice->{message};

            # Execute each requested tool call and append the results
            for my $tool_call ( @{ $choice->{message}{tool_calls} } ) {
                my $fn_name = $tool_call->{function}{name};
                # arguments is a Perl Unicode string extracted from the parsed
                # JSON response; re-encode to UTF-8 bytes before decoding again.
                my $fn_args = decode_json( encode('UTF-8', $tool_call->{function}{arguments}) );
                my $result;

                if ( $fn_name eq 'search_catalog' ) {
                    $result = Koha::Plugin::Com::BibLibre::LLMSearch::Search::Tools::execute_search($fn_args);
		    $max_tool_rounds = $round + 1 if $result->{'count'} ge 1;
                }
                elsif ( $fn_name eq 'get_authorized_values' ) {
                    $result = Koha::Plugin::Com::BibLibre::LLMSearch::Search::Tools::execute_get_authorized_values($fn_args);
                }
                elsif ( $fn_name eq 'get_authority' ) {
                    $result = Koha::Plugin::Com::BibLibre::LLMSearch::Search::Tools::execute_get_authority($fn_args);
                }
                else {
                    $result = { error => "Unknown tool: $fn_name" };
                }

                if ( $debug_mode ) {
                    eval { push @debug_log, $debug_json->encode({
                        round       => $round,
                        tool_call   => $fn_name,
                        arguments   => $fn_args,
                        tool_result => $result,
                    }) };
                    warn "LLMSearch debug encode error (tool): $@" if $@;
                }

                push @messages, {
                    role         => 'tool',
                    tool_call_id => $tool_call->{id},
                    content      => encode_json($result),
                };
            }

            # Go back to LLM with tool results
            next;
        }

        # LLM returned a normal stop — we're done
        $final_response = $response_data;
        last;
    }

    # Fallback: if we exhausted max_tool_rounds rounds without reaching a stop,
    # make one final tool-free LLM call so it can reply in the user's language.
    unless ($final_response) {
        push @messages, {
            role    => 'user',
            content =>
                '[SYSTEM INSTRUCTION] All catalog search attempts returned 0 results. '
                . 'Please inform the user that you were unable to find any matching resources '
                . 'in the catalog despite several attempts, and invite them to reformulate their '
                . 'request using different or broader terms. '
                . 'Reply in the same language as the rest of the conversation.',
        };

        # No tools in this call — the LLM must produce a plain stop response
        my $fallback_payload = { model => $model, messages => [@messages] };
        my $fallback_http = _call_llm( $user_agent, $base_url, $api_key, $fallback_payload );

        if ( $fallback_http->is_success ) {
            my $fallback_content = $fallback_http->decoded_content;
            $final_response = decode_json($fallback_content);
        }
        else {
            # Ultimate fallback if even this call fails
            $final_response = {
                choices => [
                    {
                        message => {
                            role    => 'assistant',
                            content => '<p>I was unable to find matching results. '
                                . 'Please try reformulating your request.</p>',
                        },
                        finish_reason => 'stop',
                    }
                ],
                usage => { prompt_tokens => 0, completion_tokens => 0 },
            };
        }
    }

    # Attach debug log to response when debug_mode is on
    $final_response->{_debug_log} = \@debug_log if $debug_mode && @debug_log;

    Koha::Plugin::Com::BibLibre::LLMSearch::Stats::Logger::log_request( { lang => $opac_lang, data => $final_response } );
    
    # Laisser Mojolicious gérer l'encodage UTF-8 avec openapi
    return $c->render(
        status  => 200,
        openapi => $final_response,
        format  => 'json',
        charset => 'UTF-8'
    );
}


1;
