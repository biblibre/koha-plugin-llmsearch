#!/bin/bash

# Script to run tests for the LLMSearch plugin
# This script can be run in two modes:
# 1. Directly in the plugin directory: ./run_tests.sh
# 2. In a Koha Docker container: docker exec kohadev-koha-1 bash /path/to/run_tests.sh

PLUGIN_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Running tests from: $PLUGIN_LIB"
echo ""

# Export the plugin library path for tests to use
export PLUGIN_LIB

# Add Koha libraries to path if running in KTD environment
if [ -d "/kohadevbox/koha/" ]; then
    PERL_INC="-I$PLUGIN_LIB -I/kohadevbox/koha/ -I/kohadevbox/koha/lib/"
else
    PERL_INC="-I$PLUGIN_LIB"
fi

# Run all test files
perl $PERL_INC "$PLUGIN_LIB/t/00-load.t" || exit 1
perl $PERL_INC "$PLUGIN_LIB/t/01-plugin.t" || exit 1
perl $PERL_INC "$PLUGIN_LIB/t/02-controller.t" || exit 1
perl $PERL_INC "$PLUGIN_LIB/t/03-utils.t" || exit 1

echo ""
echo "All tests passed!"
