package Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Prompt;

use Modern::Perl;
use Koha::Plugin::Com::BibLibre::LLMSearch::Search::Fields;

=head1 NAME

Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Prompt - LLM prompt management

=head1 DESCRIPTION

This module handles the construction and management of system prompts
for the LLM assistant.

=head1 FUNCTIONS

=head2 get_system_prompt

Gets the system prompt, either from plugin configuration or from the
embedded system_prompt.txt file, and injects the live search indexes.

=cut

sub get_system_prompt {
    my ($plugin, $custom_prompt) = @_;
    
    # Use custom prompt if provided (non-empty), otherwise get from plugin config or default file
    my $prompt;
    if (defined $custom_prompt && $custom_prompt ne '') {
        $prompt = $custom_prompt;
    } else {
        $prompt = $plugin->retrieve_data('system_prompt') // $plugin->mbf_read('system_prompt.txt');
    }
    
    # Inject the live index list from Koha's search_field table
    $prompt =~ s/\{\{SEARCH_INDEXES\}\}/build_index_list_text()/e;
    
    return $prompt;
}

=head2 build_index_list_text

Builds a human-readable index list from live Koha search fields.
This is a wrapper around Search::Fields::build_index_list_text for convenience.

=cut

sub build_index_list_text {
    return Koha::Plugin::Com::BibLibre::LLMSearch::Search::Fields::build_index_list_text();
}

=head2 get_fallback_message

Returns the fallback message to send to the LLM when all catalog search
attempts return 0 results.

=cut

sub get_fallback_message {
    return '[SYSTEM INSTRUCTION] All catalog search attempts returned 0 results. '
        . 'Please inform the user that you were unable to find any matching resources '
        . 'in the catalog despite several attempts, and invite them to reformulate their '
        . 'request using different or broader terms. '
        . 'Reply in the same language as the rest of the conversation.';
}

=head2 get_fallback_response

Returns a fallback response structure when the LLM call fails completely.

=cut

sub get_fallback_response {
    return {
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

1;
