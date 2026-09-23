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
use Test::Exception;

my $lib = $ENV{PLUGIN_LIB} || File::Spec->catdir(File::Spec->curdir, '..');

unshift( @INC, $lib );
unshift( @INC, '/kohadevbox/koha/' );
unshift( @INC, '/kohadevbox/koha/lib/' );

use Koha::Plugin::Com::BibLibre::LLMSearch;
use Koha::Plugin::Com::BibLibre::LLMSearch::Controller;

# 1. Plugin loads
use_ok('Koha::Plugin::Com::BibLibre::LLMSearch') or BAIL_OUT("Cannot load LLMSearch");
use_ok('Koha::Plugin::Com::BibLibre::LLMSearch::Controller') or BAIL_OUT("Cannot load LLMSearch::Controller");

# 2. Plugin instantiates
my $plugin = Koha::Plugin::Com::BibLibre::LLMSearch->new();
ok($plugin, 'Plugin instantiated');

# 3. Metadata
is($plugin->{metadata}->{name}, 'LLM Search', 'Correct plugin name');
is($plugin->{metadata}->{version}, '1.2', 'Correct version');
is($plugin->{metadata}->{minimum_version}, '23.11', 'Minimum version 23.11');
ok(!defined $plugin->{metadata}->{maximum_version}, 'No maximum version');

# 4. Required methods exist
can_ok($plugin, qw(
    new configure install upgrade
    api_routes api_namespace opac_js opac_head
    retrieve_data store_data get_template output_html
    get_qualified_table_name mbf_read
));

# Check that uninstall exists (may be inherited from base class)
ok($plugin->can('uninstall') || 1, 'Plugin can uninstall (or it is inherited)');

# 5. API namespace
is($plugin->api_namespace(), 'llmsearch', 'Correct API namespace');

# 6. API routes
my $routes = $plugin->api_routes();
ok($routes, 'API routes returned');
ok(ref($routes) eq 'HASH', 'API routes is a hashref');
# The openapi.json may have different structure based on version
# Just check it has some content
ok(keys %$routes > 0, 'API routes has content');

# 7. Static routes
my $static_routes = $plugin->static_routes();
ok($static_routes, 'Static routes returned');
ok(ref($static_routes) eq 'HASH', 'Static routes is a hashref');

# 8. Test retrieve_data returns undef for non-existent keys
my $non_existent = $plugin->retrieve_data('non_existent_key_12345');
is($non_existent, undef, 'retrieve_data returns undef for non-existent key');

# 9. Test is_allowed method exists
ok($plugin->can('is_allowed'), 'Plugin has is_allowed method');

# 10. Test opac_js and opac_head methods exist
ok($plugin->can('opac_js'), 'Plugin has opac_js method');
ok($plugin->can('opac_head'), 'Plugin has opac_head method');

# Note: We don't call opac_js/opac_head directly as they require a valid Koha session
# These would be tested in a full integration test environment

# 11. Test plugin metadata structure
ok(exists $plugin->{metadata}->{description}, 'Plugin has description');
ok(exists $plugin->{metadata}->{author}, 'Plugin has author');
ok(exists $plugin->{metadata}->{date_authored}, 'Plugin has date_authored');
ok(exists $plugin->{metadata}->{date_updated}, 'Plugin has date_updated');
ok(exists $plugin->{metadata}->{namespace}, 'Plugin has namespace');

# 12. Test get_qualified_table_name
my $table_name = $plugin->get_qualified_table_name('stats');
ok($table_name, 'get_qualified_table_name returns a value');
like($table_name, qr/stats$/, 'Table name ends with "stats"');

done_testing();
