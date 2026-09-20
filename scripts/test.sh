#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
DEVELOPER_DIRECTORY="${DEVELOPER_DIR:-$(xcode-select -p)}"
TESTING_PLUGIN="$DEVELOPER_DIRECTORY/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
TEST_ARGS=(--jobs 2)
# Some Command Line Tools releases omit this bundled plugin from the test build invocation.
if [[ -f "$TESTING_PLUGIN" ]]; then
    TEST_ARGS+=(-Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN")
fi
swift test "${TEST_ARGS[@]}" "$@"
