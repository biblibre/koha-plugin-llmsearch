package Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Chat;

use Modern::Perl;
use C4::Context;
use C4::Auth qw( get_session );
use JSON qw( encode_json decode_json );
use URI::Escape;
use Encode qw(encode);
use Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Client;
use Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Prompt;
use Koha::Plugin::Com::BibLibre::LLMSearch::Search::Tools;
use Koha::Plugin::Com::BibLibre::LLMSearch::Stats::Logger;

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

sub handle_chat_request {
    my ($c, $plugin) = @_;
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

    return $c->render(
        status  => 500,
        openapi => { error => "missing configuration" }
    ) unless $base_url and $model;

    # Get system prompt
    my $prompt = Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Prompt::get_system_prompt($plugin);
    
    my $max_tool_rounds = $plugin->retrieve_data('max_tool_rounds') // 5;
    $max_tool_rounds = 1 if $max_tool_rounds < 1;

    my $user_agent = LWP::UserAgent->new;
    $user_agent->agent("KohaLLMSearch");

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
    my $tools = Koha::Plugin::Com::BibLibre::LLMSearch::Search::Tools::get_search_tools();
    my $final_response = execute_chat_loop({
        c => $c,
        user_agent => $user_agent,
        base_url => $base_url,
        api_key => $api_key,
        model => $model,
        messages => \@messages,
        tools => $tools,
        max_tool_rounds => $max_tool_rounds,
        debug_mode => $plugin->retrieve_data('debug_mode') // 0,
    });

    # Log the request
    Koha::Plugin::Com::BibLibre::LLMSearch::Stats::Logger::log_request( { lang => $opac_lang, data => $final_response } );
    
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
    my $user_agent = $args->{user_agent};
    my $base_url = $args->{base_url};
    my $api_key = $args->{api_key};
    my $model = $args->{model};
    my $messages = $args->{messages};
    my $tools = $args->{tools};
    my $max_tool_rounds = $args->{max_tool_rounds};
    my $debug_mode = $args->{debug_mode};

    my $final_response;
    my @debug_log;
    my $debug_json = $debug_mode ? JSON->new->utf8->max_depth(2048) : undef;

    for my $round ( 1 .. $max_tool_rounds ) {
        my $chat_payload = { model => $model, messages => $messages, tools => $tools };

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
        my $choice = $response_data->{choices}[0];

        if ( $debug_mode ) {
            eval { push @debug_log, $debug_json->encode({ round => $round, response => $response_data }) };
            warn "LLMSearch debug encode error (response): $@" if $@;
        }

        # If the LLM wants to call tools, execute them and loop
        if ( $choice->{finish_reason} && $choice->{finish_reason} eq 'tool_calls' ) {
            # Append the assistant's tool_calls message to the history
            push @$messages, $choice->{message};

            # Execute each requested tool call and append the results
            my $has_results = execute_tool_calls({
                choice => $choice,
                messages => $messages,
                debug_mode => $debug_mode,
                debug_log => \@debug_log,
                debug_json => $debug_json,
                max_tool_rounds => \$max_tool_rounds,
            });

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
        push @$messages, {
            role    => 'user',
            content => Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Prompt::get_fallback_message(),
        };

        my $fallback_payload = { model => $model, messages => $messages };
        my $fallback_http = Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Client::call( $user_agent, $base_url, $api_key, $fallback_payload );

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
    my $debug_mode = $args->{debug_mode};
    my $debug_log = $args->{debug_log};
    my $debug_json = $args->{debug_json};
    my $max_tool_rounds = $args->{max_tool_rounds};
    
    my $has_results = 0;

    for my $tool_call ( @{ $choice->{message}{tool_calls} } ) {
        my $fn_name = $tool_call->{function}{name};
        # arguments is a Perl Unicode string extracted from the parsed
        # JSON response; re-encode to UTF-8 bytes before decoding again.
        my $fn_args = decode_json( encode('UTF-8', $tool_call->{function}{arguments}) );
        my $result;

        if ( $fn_name eq 'search_catalog' ) {
            $result = Koha::Plugin::Com::BibLibre::LLMSearch::Search::Tools::execute_search($fn_args);
            $has_results = 1 if $result->{'count'} ge 1;
            $$max_tool_rounds = 1 if $has_results;  # Allow one more round if we found results
        }
        elsif ( $fn_name eq 'get_authorized_values' ) {
            $result = Koha::Plugin::Com::BibLibre::LLMSearch::Search::Tools::execute_get_authorized_values($fn_args);
        }
        elsif ( $fn_name eq 'get_authority' ) {
            $result = Koha::Plugin::Com::BibLibre::LLMSearch::Search::Tools::execute_get_authority($fn_args);
        }
	elsif ( $fn_name eq 'get_search_indexes' ) {
	    $result = Koha::Plugin::Com::BibLibre::LLMSearch::Search::Tools::execute_get_search_indexes();
	}
        else {
            $result = { error => "Unknown tool: $fn_name" };
        }

        if ( $debug_mode ) {
            eval { push @$debug_log, $debug_json->encode({
                round       => 1,
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
    }

    return $has_results;
}

1;
