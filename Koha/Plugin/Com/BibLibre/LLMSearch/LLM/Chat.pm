package Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Chat;

use Modern::Perl;
use C4::Auth qw( get_session );
use JSON qw( encode_json decode_json );
use LWP::UserAgent;
use HTTP::Request;
use URI::Escape;
use Encode qw(encode);
use Koha::Plugin::Com::BibLibre::LLMSearch;
use Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Prompt;
use Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Tools;
use Koha::Plugin::Com::BibLibre::LLMSearch::Logger;

=head1 NAME

Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Chat - Chat handling logic

=head1 DESCRIPTION

This module contains the chat handling logic for the LLM Search plugin.
It manages the conversation with the LLM, tool execution, and response processing.

=head1 FUNCTIONS

=head2 handle_chat_request

Handles a chat request from the API, managing the conversation with the LLM
and executing tools as needed.

=cut

our $plugin = Koha::Plugin::Com::BibLibre::LLMSearch->new();
our $tools  = "Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Tools";

sub handle_chat_request {
    my ($c) = @_;
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

    return $c->render(
	status => 500,
	openapi => { error => "invalid input" }
    ) unless $c->openapi->valid_input;

    # Get system prompt
    my $prompt = Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Prompt::get_system_prompt($plugin);
    
    my $max_tool_rounds = $plugin->retrieve_data('max_tool_rounds') // 5;
    $max_tool_rounds = 1 if $max_tool_rounds < 1;

    # Parse incoming JSON
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

    # Agentic tool-call loop
    my $final_response = execute_chat_loop({
        c => $c,
        messages => \@messages,
        max_tool_rounds => $max_tool_rounds
    });

    # Log the request
    Koha::Plugin::Com::BibLibre::LLMSearch::Logger::log_request( { lang => $opac_lang, data => $final_response } );
    
    return $c->render(
        status  => 200,
        openapi => $final_response,
        format  => 'json',
        charset => 'UTF-8'
    );
}

=head2 execute_chat_loop

Executes the main chat loop with the LLM, handling tool calls.

=cut

sub execute_chat_loop {
    my ($args) = @_;
    my $c = $args->{c};
    my $messages = $args->{messages};
    my $max_tool_rounds = $args->{max_tool_rounds};
    my $debug_mode => $plugin->retrieve_data('debug_mode') // 0;
    my $final_response;
    my @debug_log;

    my $made_tool_call = 0;
    my $nudged         = 0;
    my $current_round  = 1;

    my $base_url = get_llm_config('base_url');
    my $model    = get_llm_config('model');
    return "missing configuration"
	unless $base_url and $model;

    while ( $current_round <= $max_tool_rounds ) {
        my $chat_payload = { model => $model, messages => $messages, tools => $tools->get_search_tools() };
        if ( $debug_mode ) {
            eval { push @debug_log, encode_json({ round => $current_round, request => $chat_payload }) };
            warn "LLMSearch debug encode error (request): $@" if $@;
        }

        my $http_response = api_call( $chat_payload );
        my $content = $http_response->decoded_content;
        return $content
	    unless ( $http_response->is_success );

        my $response_data = decode_json($content);
        my $choice = $response_data->{choices}[0];

        if ( $debug_mode ) {
            eval { push @debug_log, encode_json({ round => $current_round, response => $response_data }) };
            warn "LLMSearch debug encode error (response): $@" if $@;
        }

        # If the LLM wants to call tools, execute them and loop
        if ( $choice->{finish_reason} && $choice->{finish_reason} eq 'tool_calls' ) {
            $made_tool_call = 1;
            # Append the assistant's tool_calls message to the history
            push @$messages, $choice->{message};

            # Execute each requested tool call and append the results
            my $has_results = execute_tool_calls({
                choice => $choice,
                messages => $messages,
                debug_log => \@debug_log,
                max_tool_rounds => \$max_tool_rounds,
                current_round => $current_round,
            });

            # If we found results, inject a system message to force the LLM to stop
            # and present the results to the user
            if ($has_results) {
                push @$messages, {
                    role    => 'system',
                    content => 'You have validated search results. STOP making tool calls. '
                            . 'Present the results to the user with search links NOW. '
                            . 'Do NOT continue refining the search.',
                };
                $max_tool_rounds = $current_round + 1;
            }

            # Go back to LLM with tool results
            $current_round++;
            next;
        }

        # LLM answered without ever calling a tool. Small models sometimes
        # "simulate" the tools instead of calling them: nudge once toward
        # the real tools before accepting the answer.
        if ( !$made_tool_call && !$nudged && $current_round < $max_tool_rounds ) {
            push @$messages, $choice->{message};
            push @$messages, {
                role    => 'system',
                content => 'You answered without calling any tool. You MUST call the tools: '
                    . 'get_search_indexes first to get the field names, then search_catalog '
                    . 'to validate a search. Call the tools now.',
            };
            $nudged = 1;
            $current_round++;
            next;
        }

        # LLM returned a normal stop — we're done
        $final_response = $response_data;
        last;
    }

    # Fallback: if we exhausted max_tool_rounds rounds without reaching a stop,
    # make one final tool-free LLM call so it can reply in the user's language.
    unless ($final_response) {
        push @$messages, {
            role    => 'user',
            content => Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Prompt::get_fallback_message(),
        };

        my $fallback_payload = { model => $model, messages => $messages, think => JSON::false, stream => JSON::false };
        my $fallback_http = api_call( $fallback_payload );

        if ( $fallback_http->is_success ) {
            my $fallback_content = $fallback_http->decoded_content;
            $final_response = decode_json($fallback_content);
        }
        else {
            $final_response = Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Prompt::get_fallback_response();
        }
    }

    # Attach debug log to response when debug_mode is on
    $final_response->{_debug_log} = \@debug_log if $debug_mode && @debug_log;

    return $final_response;
}

=head2 execute_tool_calls

Executes tool calls from the LLM and appends results to messages.

=cut

sub execute_tool_calls {
    my ($args) = @_;
    my $choice = $args->{choice};
    my $messages = $args->{messages};
    my $debug_log = $args->{debug_log};
    my $max_tool_rounds = $args->{max_tool_rounds};
    my $current_round = $args->{current_round} || 1;
    my $debug_mode = $plugin->retrieve_data('debug_mode') // 0;
    for my $tool_call ( @{ $choice->{message}{tool_calls} } ) {
        my $fn_name = $tool_call->{function}{name};
        # arguments is a Perl Unicode string extracted from the parsed
        # JSON response; re-encode to UTF-8 bytes before decoding again.
        my $fn_args = decode_json( encode('UTF-8', $tool_call->{function}{arguments}) );
        my $result;
	if ( defined $tools->$fn_name ) {
	    $result = $tools->$fn_name( $fn_args );
	}
        else {
            $result = { error => "Unknown tool: $fn_name" };
        }

        if ( $debug_mode ) {
            eval { push @$debug_log, encode_json({
                round       => $current_round,
                tool_call   => $fn_name,
                arguments   => $fn_args,
                tool_result => $result,
            }) };
            warn "LLMSearch debug encode error (tool): $@" if $@;
        }

        push @$messages, {
            role         => 'tool',
            tool_call_id => $tool_call->{id},
            content      => encode_json($result),
        };

        return 1
            if ( $result->{'count'} && $result->{'count'} ge 1 );
    }
    return 0;
}

=head2 get_llm_config

Returns the value of the given key from the plugin's config.ini file (JSON
format), read with mbf_read. Falls back to the database for values stored
by previous versions.

=cut

sub get_llm_config {
    my ( $key ) = @_;
    if ( $plugin->mbf_exists('config.ini') ) {
        my $config = eval { decode_json( $plugin->mbf_read('config.ini') ) };
        warn "LLMSearch: could not read config.ini as JSON: $@" if $@;
        return $config->{$key} if ref $config eq 'HASH' and exists $config->{$key};
    }
    # Fall back to the database for values stored by previous versions
    return $plugin->retrieve_data($key);
}

=head2 call

Sends a request to the LLM API and returns the HTTP::Response object.

=cut

sub api_call {
    my ( $payload ) = @_;
    my $api_key  = get_llm_config('api_key');
    my $base_url = get_llm_config('base_url');
    my $header = [
        'Content-Type'  => 'application/json',
        'Accept'        => 'application/json',
        'Authorization' => 'Bearer ' . $api_key,
        ];
    my $req = HTTP::Request->new( 'POST', $base_url, $header, encode_json($payload) );
    my $ua = LWP::UserAgent->new;
    $ua->agent("KohaLLMSearch");
    return $ua->request($req);
}

1;
