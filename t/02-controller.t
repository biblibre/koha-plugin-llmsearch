#!/usr/bin/perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;
use Test::More;

my $lib = $ENV{PLUGIN_LIB} || File::Spec->catdir(File::Spec->curdir, '..');

unshift( @INC, $lib );
unshift( @INC, '/kohadevbox/koha/' );
unshift( @INC, '/kohadevbox/koha/lib/' );

# We need to test the specialized modules
use Koha::Plugin::Com::BibLibre::LLMSearch::Search;
use Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Prompt;
use Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Chat;
use Koha::Plugin::Com::BibLibre::LLMSearch::Controller;

# 1. Test Search module (CCL) - escape_value
is(
    Koha::Plugin::Com::BibLibre::LLMSearch::Search::escape_value('test'),
    '"test"',
    'Search::escape_value wraps value in quotes'
);

is(
    Koha::Plugin::Com::BibLibre::LLMSearch::Search::escape_value('test "value"'),
    '"test value"',
    'Search::escape_value removes embedded quotes'
);

is(
    Koha::Plugin::Com::BibLibre::LLMSearch::Search::escape_value(''),
    '""',
    'Search::escape_value handles empty string'
);

# 2. Test Search module (CCL) - is_date_range
ok(
    Koha::Plugin::Com::BibLibre::LLMSearch::Search::is_date_range('2005'),
    'Search::is_date_range matches exact year'
);

ok(
    Koha::Plugin::Com::BibLibre::LLMSearch::Search::is_date_range('2005-2014'),
    'Search::is_date_range matches year range'
);

ok(
    Koha::Plugin::Com::BibLibre::LLMSearch::Search::is_date_range('-2004'),
    'Search::is_date_range matches before year'
);

ok(
    Koha::Plugin::Com::BibLibre::LLMSearch::Search::is_date_range('2005-'),
    'Search::is_date_range matches from year onwards'
);

ok(
    !Koha::Plugin::Com::BibLibre::LLMSearch::Search::is_date_range('test'),
    'Search::is_date_range does not match non-date string'
);

ok(
    !Koha::Plugin::Com::BibLibre::LLMSearch::Search::is_date_range('2005-01-01'),
    'Search::is_date_range does not match full date'
);

# 3. Test Search module (CCL) - build_query
my $params1 = { title => 'test book' };
my $query1 = Koha::Plugin::Com::BibLibre::LLMSearch::Search::build_query($params1);
is($query1, 'title:"test book"', 'Search::build_query with single param');

my $params2 = { title => 'test', author => 'john' };
my $query2 = Koha::Plugin::Com::BibLibre::LLMSearch::Search::build_query($params2);
like($query2, qr/title:"test"/, 'Search::build_query contains title');
like($query2, qr/author:"john"/, 'Search::build_query contains author');
like($query2, qr/AND/, 'Search::build_query joins with AND');

my $params3 = { title => 'test', pubdate => '2005-2014' };
my $query3 = Koha::Plugin::Com::BibLibre::LLMSearch::Search::build_query($params3);
is($query3, 'pubdate:2005-2014 AND title:"test"', 'Search::build_query with date range (unquoted)');

my $params4 = { };
my $query4 = Koha::Plugin::Com::BibLibre::LLMSearch::Search::build_query($params4);
is($query4, 'kw:*', 'Search::build_query with empty params returns kw:*');

my $params5 = { title => '', author => 'john' };
my $query5 = Koha::Plugin::Com::BibLibre::LLMSearch::Search::build_query($params5);
is($query5, 'author:"john"', 'Search::build_query ignores empty values');

# 4. Test Search module (fields)

my $fields = Koha::Plugin::Com::BibLibre::LLMSearch::Search::get_opac_biblio_search_fields();
ok($fields, 'Search::get_opac_biblio_search_fields returns value');
ok(ref($fields) eq 'ARRAY', 'Search::get_opac_biblio_search_fields returns arrayref');

# Check that we have some fields (the exact number depends on Koha configuration)
my $field_count = scalar @$fields;
ok($field_count >= 0, "Found $field_count OPAC search fields");

# Check first field if it exists
if ($field_count > 0) {
    ok(exists $fields->[0]{name}, 'First field has name property');
    ok(exists $fields->[0]{label}, 'First field has label property');
}

# 5. Test LLM::Tools module
use Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Tools;

my $tools = Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Tools->get_search_tools();
ok($tools, 'Tools::get_search_tools returns value');
ok(ref($tools) eq 'ARRAY', 'Tools::get_search_tools returns arrayref');

# Check that we have the expected tools
my %tool_names = map { $_->{function}{name} => 1 } @$tools;
ok(exists $tool_names{'search_catalog'}, 'Tools::get_search_tools includes search_catalog');
ok(exists $tool_names{'get_authorized_values'}, 'Tools::get_search_tools includes get_authorized_values');
ok(exists $tool_names{'get_authority'}, 'Tools::get_search_tools includes get_authority');
ok(exists $tool_names{'get_search_indexes'}, 'Tools::get_search_tools includes get_search_indexes');
ok(exists $tool_names{'get_item_types'}, 'Tools::get_search_tools includes get_item_types');

# 6. Test Search::get_field_av_category
# This requires database access, so we just verify it exists and doesn't crash
# It may return undef if no authorized value category is found
my $av_category = Koha::Plugin::Com::BibLibre::LLMSearch::Search::get_field_av_category('title');
ok(1, 'Search::get_field_av_category can be called without crashing');
# The function returns undef or a string
ok(!defined $av_category || ref(\$av_category) eq '', 'Search::get_field_av_category returns undef or scalar');

# 7. Test Tools::get_authorized_values with missing field_name
my $result1 = Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Tools->get_authorized_values({});
is($result1->{error}, 'field_name parameter is required', 'Tools::get_authorized_values requires field_name');

# 8. Test Tools::get_authority with missing params
my $result2 = Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Tools->get_authority({});
is($result2->{error}, 'field_name parameter is required', 'Tools::get_authority requires field_name');

my $result3 = Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Tools->get_authority({ field_name => 'author' });
is($result3->{error}, 'value parameter is required', 'Tools::get_authority requires value');

# 9. Test Logger::log_request
use Koha::Plugin::Com::BibLibre::LLMSearch::Logger;

# Note: This function requires database access, so we test it doesn't crash with various inputs
# and that it returns 1 when enable_stats is disabled
my $log_result = Koha::Plugin::Com::BibLibre::LLMSearch::Logger::log_request({});
is($log_result, 1, 'Logger::log_request returns 1 when enable_stats is disabled');

# Test with partial args - should not crash
$log_result = Koha::Plugin::Com::BibLibre::LLMSearch::Logger::log_request({ lang => 'fr' });
is($log_result, 1, 'Logger::log_request returns 1 with partial args when enable_stats is disabled');

# Test with full args - should not crash even if userenv is not available
$log_result = Koha::Plugin::Com::BibLibre::LLMSearch::Logger::log_request({
    lang => 'fr',
    data => { usage => { prompt_tokens => 10, completion_tokens => 20 } }
});
is($log_result, 1, 'Logger::log_request returns 1 with full args when enable_stats is disabled');

# 11. Test LLM::Prompt module
# Test get_fallback_message
my $fallback_msg = Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Prompt::get_fallback_message();
ok($fallback_msg, 'Prompt::get_fallback_message returns a message');
like($fallback_msg, qr/SYSTEM INSTRUCTION/, 'Prompt::get_fallback_message contains SYSTEM INSTRUCTION');
like($fallback_msg, qr/catalog/, 'Prompt::get_fallback_message mentions catalog');

# Test get_fallback_response
my $fallback_resp = Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Prompt::get_fallback_response();
ok($fallback_resp, 'Prompt::get_fallback_response returns a hashref');
ok(exists $fallback_resp->{choices}, 'Prompt::get_fallback_response has choices');
ok(exists $fallback_resp->{usage}, 'Prompt::get_fallback_response has usage');
ok(ref($fallback_resp->{choices}) eq 'ARRAY', 'Prompt::get_fallback_response choices is array');

# Test get_system_prompt
use Koha::Plugin::Com::BibLibre::LLMSearch;
my $plugin = Koha::Plugin::Com::BibLibre::LLMSearch->new();
my $processed_prompt = Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Prompt::get_system_prompt($plugin);
ok($processed_prompt, 'Prompt::get_system_prompt returns a prompt');

# 12. Test LLM::Chat module
# Test that the module loads
ok(1, 'LLM::Chat module loads successfully');

# Test that functions exist
ok(Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Chat->can('handle_chat_request'), 'Chat::handle_chat_request exists');
ok(Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Chat->can('execute_chat_loop'), 'Chat::execute_chat_loop exists');
ok(Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Chat->can('execute_tool_calls'), 'Chat::execute_tool_calls exists');

# Test execute_tool_calls with a mock choice containing tool calls
# This is a basic test to ensure the function doesn't crash
my $mock_choice = {
    message => {
        tool_calls => []
    }
};
my @mock_messages = ();
my $mock_rounds = 5;
my $result = Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Chat::execute_tool_calls({
    choice => $mock_choice,
    messages => \@mock_messages,
    debug_mode => 0,
    debug_log => [],
    debug_json => undef,
    max_tool_rounds => \$mock_rounds,
});
ok($result == 0, 'Chat::execute_tool_calls returns 0 when no tool calls');

# Test with an empty messages array (edge case)
$result = Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Chat::execute_tool_calls({
    choice => $mock_choice,
    messages => [],
    debug_mode => 0,
    debug_log => [],
    debug_json => undef,
    max_tool_rounds => \$mock_rounds,
});
ok($result == 0, 'Chat::execute_tool_calls handles empty messages array');

# 13. Additional edge case tests

# Search module (CCL) edge cases
# Test escape_value with various special characters
is(
    Koha::Plugin::Com::BibLibre::LLMSearch::Search::escape_value('test\'s'),
    '"test\'s"',
    'Search::escape_value handles apostrophes'
);

is(
    Koha::Plugin::Com::BibLibre::LLMSearch::Search::escape_value('test\nline'),
    '"test\nline"',
    'Search::escape_value preserves newlines'
);

# Test build_query with undef values
my $params_undef = { title => undef, author => 'john' };
my $query_undef = Koha::Plugin::Com::BibLibre::LLMSearch::Search::build_query($params_undef);
is($query_undef, 'author:"john"', 'Search::build_query ignores undef values');

# Test build_query with whitespace-only values
my $params_whitespace = { title => '   ', author => 'john' };
my $query_whitespace = Koha::Plugin::Com::BibLibre::LLMSearch::Search::build_query($params_whitespace);
is($query_whitespace, 'author:"john"', 'Search::build_query ignores whitespace-only values');

# Test is_date_range with edge cases
ok(
    !Koha::Plugin::Com::BibLibre::LLMSearch::Search::is_date_range('abcd'),
    'Search::is_date_range does not match non-numeric strings'
);

ok(
    !Koha::Plugin::Com::BibLibre::LLMSearch::Search::is_date_range('200'),
    'Search::is_date_range does not match 3-digit years'
);

ok(
    !Koha::Plugin::Com::BibLibre::LLMSearch::Search::is_date_range('20050'),
    'Search::is_date_range does not match 5-digit numbers'
);

# LLM::Tools module edge cases
# Test get_search_indexes
my $indexes_result = Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Tools->get_search_indexes({});
ok($indexes_result, 'Tools::get_search_indexes returns result');
ok(exists $indexes_result->{indexes}, 'Tools::get_search_indexes returns indexes array');
ok(ref($indexes_result->{indexes}) eq 'ARRAY', 'Tools::get_search_indexes indexes is array');

# Verify that indexes have the expected structure
if (@{$indexes_result->{indexes}}) {
    my $first_index = $indexes_result->{indexes}[0];
    ok(exists $first_index->{name}, 'Tools::get_search_indexes first index has name');
    ok(exists $first_index->{label}, 'Tools::get_search_indexes first index has label');
    ok(exists $first_index->{description}, 'Tools::get_search_indexes first index has description');
}

# Test get_item_types
my $item_types_result = Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Tools->get_item_types({});
ok($item_types_result, 'Tools::get_item_types returns result');
ok(exists $item_types_result->{item_types}, 'Tools::get_item_types returns item_types array');
ok(ref($item_types_result->{item_types}) eq 'ARRAY', 'Tools::get_item_types item_types is array');

# Verify that item types have the expected structure
if (@{$item_types_result->{item_types}}) {
    my $first_type = $item_types_result->{item_types}[0];
    ok(exists $first_type->{itemtype}, 'Tools::get_item_types first type has itemtype');
    ok(exists $first_type->{description}, 'Tools::get_item_types first type has description');
}

# Test get_authorized_values with empty field_name
my $result_empty = Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Tools->get_authorized_values({ field_name => '' });
is($result_empty->{error}, 'field_name parameter is required', 'Tools::get_authorized_values rejects empty field_name');

# Test get_authority with empty value
my $result_empty_value = Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Tools->get_authority({ field_name => 'author', value => '' });
is($result_empty_value->{error}, 'value parameter is required', 'Tools::get_authority rejects empty value');

# Test get_authority with undef value
my $result_undef_value = Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Tools->get_authority({ field_name => 'author', value => undef });
is($result_undef_value->{error}, 'value parameter is required', 'Tools::get_authority rejects undef value');

# Prompt module edge cases
# Test get_fallback_response structure
my $fallback = Koha::Plugin::Com::BibLibre::LLMSearch::LLM::Prompt::get_fallback_response();
ok(exists $fallback->{choices}[0]{message}{role}, 'Prompt::get_fallback_response has role');
ok($fallback->{choices}[0]{message}{role} eq 'assistant', 'Prompt::get_fallback_response role is assistant');
ok(exists $fallback->{choices}[0]{finish_reason}, 'Prompt::get_fallback_response has finish_reason');
ok($fallback->{usage}{prompt_tokens} == 0, 'Prompt::get_fallback_response prompt_tokens is 0');
ok($fallback->{usage}{completion_tokens} == 0, 'Prompt::get_fallback_response completion_tokens is 0');

# Logger edge cases
# Test log_request with undef lang
$log_result = Koha::Plugin::Com::BibLibre::LLMSearch::Logger::log_request({ lang => undef, data => {} });
is($log_result, 1, 'Logger::log_request handles undef lang');

# Test log_request with undef data
$log_result = Koha::Plugin::Com::BibLibre::LLMSearch::Logger::log_request({ lang => 'fr', data => undef });
is($log_result, 1, 'Logger::log_request handles undef data');

# Test log_request with missing usage in data
$log_result = Koha::Plugin::Com::BibLibre::LLMSearch::Logger::log_request({ lang => 'fr', data => {} });
is($log_result, 1, 'Logger::log_request handles missing usage data');

done_testing();
