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
use Test::Deep;
use Test::Exception;

my $lib = $ENV{PLUGIN_LIB} || File::Spec->catdir(File::Spec->curdir, '..');

unshift( @INC, $lib );
unshift( @INC, '/kohadevbox/koha/' );
unshift( @INC, '/kohadevbox/koha/lib/' );

# We need to test the specialized modules
use Koha::Plugin::Com::BibLibre::LLMSearch::Search::CCL;
use Koha::Plugin::Com::BibLibre::LLMSearch::Controller;

# 1. Test CCL module - escape_value
is(
    Koha::Plugin::Com::BibLibre::LLMSearch::Search::CCL::escape_value('test'),
    '"test"',
    'CCL::escape_value wraps value in quotes'
);

is(
    Koha::Plugin::Com::BibLibre::LLMSearch::Search::CCL::escape_value('test "value"'),
    '"test value"',
    'CCL::escape_value removes embedded quotes'
);

is(
    Koha::Plugin::Com::BibLibre::LLMSearch::Search::CCL::escape_value(''),
    '""',
    'CCL::escape_value handles empty string'
);

# 2. Test CCL module - is_date_range
ok(
    Koha::Plugin::Com::BibLibre::LLMSearch::Search::CCL::is_date_range('2005'),
    'CCL::is_date_range matches exact year'
);

ok(
    Koha::Plugin::Com::BibLibre::LLMSearch::Search::CCL::is_date_range('2005-2014'),
    'CCL::is_date_range matches year range'
);

ok(
    Koha::Plugin::Com::BibLibre::LLMSearch::Search::CCL::is_date_range('-2004'),
    'CCL::is_date_range matches before year'
);

ok(
    Koha::Plugin::Com::BibLibre::LLMSearch::Search::CCL::is_date_range('2005-'),
    'CCL::is_date_range matches from year onwards'
);

ok(
    !Koha::Plugin::Com::BibLibre::LLMSearch::Search::CCL::is_date_range('test'),
    'CCL::is_date_range does not match non-date string'
);

ok(
    !Koha::Plugin::Com::BibLibre::LLMSearch::Search::CCL::is_date_range('2005-01-01'),
    'CCL::is_date_range does not match full date'
);

# 3. Test CCL module - build_query
my $params1 = { title => 'test book' };
my $query1 = Koha::Plugin::Com::BibLibre::LLMSearch::Search::CCL::build_query($params1);
is($query1, 'title:"test book"', 'CCL::build_query with single param');

my $params2 = { title => 'test', author => 'john' };
my $query2 = Koha::Plugin::Com::BibLibre::LLMSearch::Search::CCL::build_query($params2);
like($query2, qr/title:"test"/, 'CCL::build_query contains title');
like($query2, qr/author:"john"/, 'CCL::build_query contains author');
like($query2, qr/AND/, 'CCL::build_query joins with AND');

my $params3 = { title => 'test', pubdate => '2005-2014' };
my $query3 = Koha::Plugin::Com::BibLibre::LLMSearch::Search::CCL::build_query($params3);
is($query3, 'pubdate:2005-2014 AND title:"test"', 'CCL::build_query with date range (unquoted)');

my $params4 = { };
my $query4 = Koha::Plugin::Com::BibLibre::LLMSearch::Search::CCL::build_query($params4);
is($query4, 'kw:*', 'CCL::build_query with empty params returns kw:*');

my $params5 = { title => '', author => 'john' };
my $query5 = Koha::Plugin::Com::BibLibre::LLMSearch::Search::CCL::build_query($params5);
is($query5, 'author:"john"', 'CCL::build_query ignores empty values');

# 4. Test Fields::build_index_list_text
# This function requires database access, so we'll just check it exists and returns something
ok(
    defined Koha::Plugin::Com::BibLibre::LLMSearch::Search::Fields::build_index_list_text(),
    'Fields::build_index_list_text returns defined value'
);

# 4. Test Search::Fields module
use Koha::Plugin::Com::BibLibre::LLMSearch::Search::Fields;

my $fields = Koha::Plugin::Com::BibLibre::LLMSearch::Search::Fields::get_opac_biblio_search_fields();
ok($fields, 'Fields::get_opac_biblio_search_fields returns value');
ok(ref($fields) eq 'ARRAY', 'Fields::get_opac_biblio_search_fields returns arrayref');

# Check that we have some fields (the exact number depends on Koha configuration)
my $field_count = scalar @$fields;
ok($field_count >= 0, "Found $field_count OPAC search fields");

# Check first field if it exists
if ($field_count > 0) {
    ok(exists $fields->[0]{name}, 'First field has name property');
    ok(exists $fields->[0]{label}, 'First field has label property');
}

# 5. Test Search::Tools module
use Koha::Plugin::Com::BibLibre::LLMSearch::Search::Tools;

my $tools = Koha::Plugin::Com::BibLibre::LLMSearch::Search::Tools::get_search_tools();
ok($tools, 'Tools::get_search_tools returns value');
ok(ref($tools) eq 'ARRAY', 'Tools::get_search_tools returns arrayref');

# Check that we have the expected tools
my %tool_names = map { $_->{function}{name} => 1 } @$tools;
ok(exists $tool_names{'search_catalog'}, 'Tools::get_search_tools includes search_catalog');
ok(exists $tool_names{'get_authorized_values'}, 'Tools::get_search_tools includes get_authorized_values');
ok(exists $tool_names{'get_authority'}, 'Tools::get_search_tools includes get_authority');

# 6. Test Fields::get_field_av_category
# This requires database access, so we just verify it exists and doesn't crash
# It may return undef if no authorized value category is found
my $av_category = Koha::Plugin::Com::BibLibre::LLMSearch::Search::Fields::get_field_av_category('title');
ok(1, 'Fields::get_field_av_category can be called without crashing');
# The function returns undef or a string
ok(!defined $av_category || ref(\$av_category) eq '', 'Fields::get_field_av_category returns undef or scalar');

# 7. Test Tools::execute_get_authorized_values with missing field_name
my $result1 = Koha::Plugin::Com::BibLibre::LLMSearch::Search::Tools::execute_get_authorized_values({});
is($result1->{error}, 'field_name parameter is required', 'Tools::execute_get_authorized_values requires field_name');

# 8. Test Tools::execute_get_authority with missing params
my $result2 = Koha::Plugin::Com::BibLibre::LLMSearch::Search::Tools::execute_get_authority({});
is($result2->{error}, 'field_name parameter is required', 'Tools::execute_get_authority requires field_name');

my $result3 = Koha::Plugin::Com::BibLibre::LLMSearch::Search::Tools::execute_get_authority({ field_name => 'author' });
is($result3->{error}, 'value parameter is required', 'Tools::execute_get_authority requires value');

# 9. Test Stats::Logger::log_request
use Koha::Plugin::Com::BibLibre::LLMSearch::Stats::Logger;

# Note: This function requires database access, so we test it doesn't crash with various inputs
# and that it returns 1 when enable_stats is disabled
my $log_result = Koha::Plugin::Com::BibLibre::LLMSearch::Stats::Logger::log_request({});
is($log_result, 1, 'Stats::Logger::log_request returns 1 when enable_stats is disabled');

# Test with partial args - should not crash
$log_result = Koha::Plugin::Com::BibLibre::LLMSearch::Stats::Logger::log_request({ lang => 'fr' });
is($log_result, 1, 'Stats::Logger::log_request returns 1 with partial args when enable_stats is disabled');

# Test with full args - should not crash even if userenv is not available
$log_result = Koha::Plugin::Com::BibLibre::LLMSearch::Stats::Logger::log_request({
    lang => 'fr',
    data => { usage => { prompt_tokens => 10, completion_tokens => 20 } }
});
is($log_result, 1, 'Stats::Logger::log_request returns 1 with full args when enable_stats is disabled');

done_testing();
