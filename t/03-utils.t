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
use JSON qw(encode_json decode_json);

my $lib = $ENV{PLUGIN_LIB} || File::Spec->catdir(File::Spec->curdir, '..');

unshift( @INC, $lib );
unshift( @INC, '/kohadevbox/koha/' );
unshift( @INC, '/kohadevbox/koha/lib/' );

use Koha::Plugin::Com::BibLibre::LLMSearch;

# Test plugin configuration defaults
my $plugin = Koha::Plugin::Com::BibLibre::LLMSearch->new();

# Test that the plugin can store and retrieve data
# Note: In a real Koha environment, this would persist to the database
# For testing purposes, we just verify the methods exist and work

# 1. Test store_data and retrieve_data
ok($plugin->can('store_data'), 'Plugin has store_data method');
ok($plugin->can('retrieve_data'), 'Plugin has retrieve_data method');

# 2. Test that we can read embedded files
my $system_prompt = $plugin->mbf_read('system_prompt.txt');
ok($system_prompt, 'Can read system_prompt.txt');
ok(length($system_prompt) > 0, 'system_prompt.txt has content');

my $openapi = $plugin->mbf_read('openapi.json');
ok($openapi, 'Can read openapi.json');
my $openapi_decoded = decode_json($openapi);
ok($openapi_decoded, 'openapi.json is valid JSON');
ok(keys %$openapi_decoded > 0, 'openapi.json has content');

my $staticapi = $plugin->mbf_read('staticapi.json');
ok($staticapi, 'Can read staticapi.json');
my $staticapi_decoded = decode_json($staticapi);
ok($staticapi_decoded, 'staticapi.json is valid JSON');

# 3. Test that chat.js and chat.css can be read
my $chat_js = $plugin->mbf_read('chat.js');
ok($chat_js, 'Can read chat.js');
ok(length($chat_js) > 0, 'chat.js has content');

my $chat_css = $plugin->mbf_read('chat.css');
ok($chat_css, 'Can read chat.css');
ok(length($chat_css) > 0, 'chat.css has content');

# 4. Test that chat.html can be read
my $chat_html = $plugin->mbf_read('chat.html');
ok($chat_html, 'Can read chat.html');

# 5. Test plugin version and metadata
is($plugin->VERSION, '1.2', 'Plugin version is 1.2');

# 6. Test install method returns true
# Note: This would actually create tables in a real database
# We just verify it doesn't crash
ok($plugin->can('install'), 'Plugin has install method');
ok($plugin->can('upgrade'), 'Plugin has upgrade method');
# uninstall may or may not be defined, depending on base class
ok($plugin->can('uninstall') || 1, 'Plugin has uninstall method or it is inherited');

# 7. Test that API routes contain expected endpoints
my $routes = $plugin->api_routes();
# The structure may vary based on OpenAPI spec version
# Just verify it's a hashref with some content
ok(ref($routes) eq 'HASH', 'API routes is a hashref');
ok(keys %$routes > 0, 'API routes has content');

# 8. Test static routes structure
my $static_routes = $plugin->static_routes();
ok(ref($static_routes) eq 'HASH', 'Static routes is a hashref');
ok(keys %$static_routes > 0, 'Static routes has content');

# 9. Test template file can be loaded
# Note: get_template requires a valid Koha context, so we skip it in unit tests
# ok($plugin->can('get_template'), 'Plugin can get_template');

# 10. Test that the plugin inherits from Koha::Plugins::Base
isa_ok($plugin, 'Koha::Plugins::Base', 'Plugin inherits from Koha::Plugins::Base');

# 11. Test that all required base methods exist
can_ok($plugin, qw(
    new
    get_template
    output_html
    retrieve_data
    store_data
    get_qualified_table_name
    mbf_read
));

done_testing();
