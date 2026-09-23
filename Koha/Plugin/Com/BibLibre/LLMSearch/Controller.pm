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
    $prompt =~ s/\{\{SEARCH_INDEXES\}\}/_build_index_list_text()/e;
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
    my $tools          = _get_search_tools();
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

        my $http_response = _call_llm( $user_agent, $base_url, $api_key, $chat_payload );

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
                    $result = _execute_search($fn_args);
                }
                elsif ( $fn_name eq 'get_authorized_values' ) {
                    $result = _execute_get_authorized_values($fn_args);
                }
                elsif ( $fn_name eq 'get_authority' ) {
                    $result = _execute_get_authority($fn_args);
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

    log_request( { lang => $opac_lang, data => $final_response } );
    
    # Laisser Mojolicious gérer l'encodage UTF-8 avec openapi
    return $c->render(
        status  => 200,
        openapi => $final_response,
        format  => 'json',
        charset => 'UTF-8'
    );
}

# -------------------------------------------------------------------------
# _call_llm( $ua, $base_url, $api_key, \%payload ) -> HTTP::Response
# -------------------------------------------------------------------------
sub _call_llm {
    my ( $ua, $base_url, $api_key, $payload ) = @_;
    my $header = [
        'Content-Type'  => 'application/json',
        'Accept'        => 'application/json',
        'Authorization' => 'Bearer ' . $api_key,
    ];
    my $req = HTTP::Request->new( 'POST', $base_url, $header, encode_json($payload) );
    return $ua->request($req);
}

# -------------------------------------------------------------------------
# _get_opac_biblio_search_fields() -> \@fields
# Returns all search fields from Koha's search_field table that are
# enabled for the OPAC and mapped to the biblios index.
# -------------------------------------------------------------------------
sub _get_opac_biblio_search_fields {
    require Koha::SearchFields;

    my @fields;
    my $all = Koha::SearchFields->search( { opac => 1 }, { order_by => 'label' } );
    while ( my $field = $all->next ) {
        push @fields, { name => $field->name, label => $field->label }
            if $field->is_mapped_biblios;
    }
    return \@fields;
}

# -------------------------------------------------------------------------
# _build_index_list_text() -> $string
# Builds a human-readable index list from live Koha search fields,
# for injection into the system prompt via the {{SEARCH_INDEXES}} placeholder.
# -------------------------------------------------------------------------
sub _build_index_list_text {
    my $fields = _get_opac_biblio_search_fields();

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

# -------------------------------------------------------------------------
# _get_search_tools() -> \@tools
# Returns the OpenAI-compatible tool definition for search_catalog,
# with parameters built dynamically from Koha's live search field list.
# -------------------------------------------------------------------------
sub _get_search_tools {
    my $fields = _get_opac_biblio_search_fields();

    my %properties;
    for my $field (@$fields) {
        my $desc = $field->{label};
        # For date fields, add CCL date-range syntax instructions
        if ( $field->{name} =~ /date/i ) {
            $desc .= '. Use CCL date range syntax (no quotes, no < or > signs): '
                   . 'exact year → "2005"; '
                   . 'range → "2005-2014"; '
                   . 'before 2005 (i.e. up to 2004) → "-2004"; '
                   . 'from 2005 onwards → "2005-".';
        }
        # Flag fields backed by authorized values
        if ( _get_field_av_category( $field->{name} ) ) {
            $desc .= ' [controlled vocabulary — call get_authorized_values("'
                   . $field->{name}
                   . '") to get the list of valid values before searching]';
        }
        $properties{ $field->{name} } = {
            type        => 'string',
            description => $desc,
        };
    }

    # Safety net: if no fields are configured yet, expose a generic keyword param
    unless (%properties) {
        %properties = (
            keyword => { type => 'string', description => 'General keyword search' },
        );
    }

    return [
        {
            type     => 'function',
            function => {
                name        => 'search_catalog',
                description =>
                    'Search the library catalog and return the number of matching results. '
                    . 'Call this tool to verify that a search will return results BEFORE including a link in your response. '
                    . 'If the count is 0, adjust the criteria (broader terms, fewer constraints, synonyms) and try again.',
                parameters => {
                    type       => 'object',
                    properties => \%properties,
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
                name        => 'get_authority',
                description =>
                    'Check if an authority exists using Koha\'s authority search system. '
                    . 'Call this when a field description says "[authority field]" '
                    . 'to verify that the authority value exists before searching. '
                    . 'Returns: exists (bool), authid, count, and heading if found.',
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
    ];
}

# -------------------------------------------------------------------------
# _escape_ccl_value( $value ) -> $quoted_value
# Wraps a value in double quotes for CCL phrase search and removes any
# embedded quotes to prevent query injection.
# -------------------------------------------------------------------------
sub _escape_ccl_value {
    my ($val) = @_;
    $val =~ s/"//g;
    return qq("$val");
}

# -------------------------------------------------------------------------
# _is_ccl_date_range( $value ) -> bool
# Returns true if the value looks like a CCL date range expression that
# must NOT be quoted: e.g. "2005", "-2004", "2005-2014", "2005-"
# -------------------------------------------------------------------------
sub _is_ccl_date_range {
    my ($val) = @_;
    return $val =~ /^-?\d{4}(-\d{4})?$|^\d{4}-$/;
}

# -------------------------------------------------------------------------
# _build_ccl_query( \%params ) -> $ccl_string
# Converts structured search parameters into a CCL query string.
# Iterates over whatever field names the LLM provided (which are the live
# Koha search_field names) and builds fieldname:"value" expressions.
# Date range values (e.g. -2004, 2005-2014, 2005) are passed unquoted.
# -------------------------------------------------------------------------
sub _build_ccl_query {
    my ($params) = @_;
    my @parts;

    for my $field_name ( sort keys %$params ) {
        my $val = $params->{$field_name};
        next unless defined $val && $val ne '';
        my $ccl_val = _is_ccl_date_range($val) ? $val : _escape_ccl_value($val);
        push @parts, $field_name . ':' . $ccl_val;
    }

    return @parts ? join( ' AND ', @parts ) : 'kw:*';
}

# -------------------------------------------------------------------------
# _execute_search( \%params ) -> { count => N }
# Runs a live Koha catalog search and returns the result count.
# -------------------------------------------------------------------------
sub _execute_search {
    my ($params) = @_;

    require Koha::SearchEngine::Search;
    require Koha::SearchEngine;

    my $searcher = Koha::SearchEngine::Search->new(
        { index => $Koha::SearchEngine::BIBLIOS_INDEX }
    );

    my $query = _build_ccl_query($params);
    my ( $error, $marcresults, $total_hits ) =
        $searcher->simple_search_compat( $query, 0, 1 );

    if ($error) {
        warn "LLMSearch: search error for query '$query': $error";
        return { count => 0, query => $query, error => "$error" };
    }

    return { count => ( $total_hits // 0 ), query => $query };
}

# -------------------------------------------------------------------------
# _get_field_av_category( $field_name ) -> $category_string or undef
# Traces search_field → search_marc_to_field → search_marc_map →
# marc_subfield_structure to find whether the field is backed by an
# authorized value category. Returns the category name or undef.
# -------------------------------------------------------------------------
sub _get_field_av_category {
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

# -------------------------------------------------------------------------
# _execute_get_authorized_values( \%params ) -> { category=>, values=>[] }
# Returns the list of valid authorized values for a given search field.
# -------------------------------------------------------------------------
sub _execute_get_authorized_values {
    my ($params) = @_;

    my $field_name = $params->{field_name};
    return { error => 'field_name parameter is required' }
        unless $field_name;

    my $category = _get_field_av_category($field_name);
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

# -------------------------------------------------------------------------
# _execute_get_authority( \%params ) -> { exists => bool, authid => int or undef, count => int }
# Checks if an authority exists in the database for a given search field.
# Uses Koha::SearchEngine::Search->search_auth_compat for proper authority search.
# -------------------------------------------------------------------------
sub _execute_get_authority {
    my ($params) = @_;

    my $field_name = $params->{field_name};
    my $value      = $params->{value};

    return { error => 'field_name parameter is required' }
        unless $field_name;
    return { error => 'value parameter is required' }
        unless defined $value;

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

sub log_request {
    my $args      = shift;
    my $opac_lang = $args->{'lang'};
    my $response  = $args->{'data'};

    return 1 unless ( $plugin->retrieve_data('enable_stats') );

    my $userenv = C4::Context->userenv;
    my $patron  = Koha::Patrons->find( $userenv->{'number'} )->unblessed();

    my $dbh   = C4::Context->dbh;
    my $table = $plugin->get_qualified_table_name('stats');

    my $query = "INSERT INTO $table (
                     opac_lang,
                     tokens_sent,
                     tokens_received
                 ) VALUES (
                     '$opac_lang',
                     '$response->{usage}{prompt_tokens}',
                     '$response->{usage}{completion_tokens}'
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
            '$patron->{categorycode}',
            '$patron->{branchcode}',
            '$enrolledyear',
            '$birthyear',
            '$patron->{sort1}',
            '$patron->{sort2}',
            '$opac_lang',
            '$response->{usage}{prompt_tokens}',
            '$response->{usage}{completion_tokens}'
        )";

    return $dbh->do($query);
}



1;
