# Testing the LLM Search Koha Plugin

This document describes how to run the test suite for the LLM Search Koha plugin.

## Test Files

The plugin includes the following test files in the `t/` directory:

- **00-load.t** - Tests that all Perl modules can be loaded correctly
- **01-plugin.t** - Tests the main plugin class (Koha::Plugin::Com::BibLibre::LLMSearch)
- **02-controller.t** - Tests the controller internal functions
- **03-utils.t** - Tests utility functions and configuration

## Running Tests

### In a Koha Testing Docker (KTD) Environment

If you have a Koha Testing Docker environment running:

```bash
# Run all tests
docker exec kohadev-koha-1 bash -c "cd /kohadevbox/plugins/koha-plugin-llmsearch && bash run_tests.sh"

# Or run tests individually
docker exec kohadev-koha-1 bash -c "cd /kohadevbox/plugins/koha-plugin-llmsearch/t && perl -I. -I/kohadevbox/koha/ -I/kohadevbox/koha/lib/ 00-load.t"
```

### In a Standard Koha Installation

If you have Koha installed directly on your system:

```bash
# Navigate to the plugin directory
cd /path/to/koha-plugin-llmsearch

# Run all tests
bash run_tests.sh

# Or run tests individually
perl -I. t/00-load.t
perl -I. t/01-plugin.t
perl -I. t/02-controller.t
perl -I. t/03-utils.t
```

### Manually with Custom Paths

You can also run tests manually by setting the appropriate Perl include paths:

```bash
PLUGIN_LIB=/path/to/koha-plugin-llmsearch \
KOHA_LIB=/path/to/koha \
perl -I$PLUGIN_LIB -I$KOHA_LIB -I$KOHA_LIB/lib t/01-plugin.t
```

## Test Coverage

The tests cover the following functionality:

### Plugin Class (LLMSearch.pm)
- Plugin metadata (name, version, author, etc.)
- Plugin instantiation
- API routes and namespace
- Configuration methods (retrieve_data, store_data)
- Table name generation
- File reading (mbf_read)
- Template loading

### Controller Functions (Controller.pm)
- CCL value escaping (`_escape_ccl_value`)
- Date range detection (`_is_ccl_date_range`)
- CCL query building (`_build_ccl_query`)
- Search tool definitions (`_get_search_tools`)
- OPAC search field retrieval (`_get_opac_biblio_search_fields`)
- Index list text building (`_build_index_list_text`)
- Authorized value category retrieval (`_get_field_av_category`)
- Authorized values execution (`_execute_get_authorized_values`)
- Authority checking (`_execute_get_authority`)

## Notes

1. Some tests that require database access may return different results depending on your Koha configuration. These tests are designed to pass as long as the functions don't crash.

2. Tests that require a valid Koha user session (like `is_allowed`, `opac_js`, `opac_head`) are only checked for method existence, not for their return values, as they require a proper Koha environment.

3. The test suite is designed to work both in a full Koha environment and in a development/testing environment where all dependencies may not be available.

## Adding New Tests

When adding new functionality to the plugin, please add corresponding tests to the appropriate test file. Follow the existing test structure and naming conventions.

For new internal controller functions (prefixed with `_`), add tests to `02-controller.t`.

For new plugin methods, add tests to `01-plugin.t`.

For utility and configuration tests, add tests to `03-utils.t`.
