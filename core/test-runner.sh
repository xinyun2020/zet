#!/bin/bash
# Zet Test Runner — minimal test framework for shell scripts
# Usage: source this file in your test scripts, then call assert_* functions
# Dependencies: bash
#
# Example:
#   #!/bin/bash
#   source "$(dirname "$0")/../core/test-runner.sh"
#
#   test_my_feature() {
#       setup
#       # ... test logic ...
#       assert_file_exists "$file" "file was created"
#       teardown
#   }
#
#   test_my_feature
#   zet_test_results

# --- State ---
ZET_TESTS_RUN=0
ZET_TESTS_PASSED=0
ZET_TESTS_FAILED=0
ZET_FAILURES=""

# --- Test isolation ---
# Call setup before each test to get an isolated temp directory.
# $TEST_HOME becomes a fresh HOME, $TEST_TMP is a working directory.
ZET_TEST_HOME=""

zet_test_setup() {
    ZET_TEST_HOME=$(mktemp -d)
    export TEST_HOME="$ZET_TEST_HOME"
    export TEST_TMP="$ZET_TEST_HOME/tmp"
    mkdir -p "$TEST_TMP"
}

zet_test_teardown() {
    [ -n "$ZET_TEST_HOME" ] && rm -rf "$ZET_TEST_HOME"
    ZET_TEST_HOME=""
}

# --- Assertions ---

zet_pass() { ZET_TESTS_PASSED=$((ZET_TESTS_PASSED + 1)); echo "  PASS: $1"; }
zet_fail() { ZET_TESTS_FAILED=$((ZET_TESTS_FAILED + 1)); ZET_FAILURES="$ZET_FAILURES\n  FAIL: $1"; echo "  FAIL: $1"; }

assert_file_exists() {
    local file="$1" msg="$2"
    ZET_TESTS_RUN=$((ZET_TESTS_RUN + 1))
    if [ -f "$file" ]; then zet_pass "$msg"; else zet_fail "$msg — file not found: $file"; fi
}

assert_file_not_exists() {
    local file="$1" msg="$2"
    ZET_TESTS_RUN=$((ZET_TESTS_RUN + 1))
    if [ ! -f "$file" ] && [ ! -d "$file" ]; then zet_pass "$msg"; else zet_fail "$msg — exists: $file"; fi
}

assert_dir_exists() {
    local dir="$1" msg="$2"
    ZET_TESTS_RUN=$((ZET_TESTS_RUN + 1))
    if [ -d "$dir" ]; then zet_pass "$msg"; else zet_fail "$msg — dir not found: $dir"; fi
}

assert_dir_not_exists() {
    local dir="$1" msg="$2"
    ZET_TESTS_RUN=$((ZET_TESTS_RUN + 1))
    if [ ! -d "$dir" ]; then zet_pass "$msg"; else zet_fail "$msg — dir exists: $dir"; fi
}

assert_contains() {
    local file="$1" pattern="$2" msg="$3"
    ZET_TESTS_RUN=$((ZET_TESTS_RUN + 1))
    if grep -q "$pattern" "$file" 2>/dev/null; then zet_pass "$msg"; else zet_fail "$msg — pattern '$pattern' not in $file"; fi
}

assert_not_contains() {
    local file="$1" pattern="$2" msg="$3"
    ZET_TESTS_RUN=$((ZET_TESTS_RUN + 1))
    if ! grep -q "$pattern" "$file" 2>/dev/null; then zet_pass "$msg"; else zet_fail "$msg — pattern '$pattern' found in $file"; fi
}

assert_output_contains() {
    local output="$1" pattern="$2" msg="$3"
    ZET_TESTS_RUN=$((ZET_TESTS_RUN + 1))
    if echo "$output" | grep -q "$pattern"; then zet_pass "$msg"; else zet_fail "$msg — pattern '$pattern' not in output"; fi
}

assert_output_not_contains() {
    local output="$1" pattern="$2" msg="$3"
    ZET_TESTS_RUN=$((ZET_TESTS_RUN + 1))
    if ! echo "$output" | grep -q "$pattern"; then zet_pass "$msg"; else zet_fail "$msg — pattern '$pattern' in output"; fi
}

# String-in-string checks (literal match, no file needed)
assert_contains_str() {
    local haystack="$1" needle="$2" msg="$3"
    ZET_TESTS_RUN=$((ZET_TESTS_RUN + 1))
    if echo "$haystack" | grep -qF "$needle"; then zet_pass "$msg"; else zet_fail "$msg — '$needle' not found in string"; fi
}

assert_not_contains_str() {
    local haystack="$1" needle="$2" msg="$3"
    ZET_TESTS_RUN=$((ZET_TESTS_RUN + 1))
    if ! echo "$haystack" | grep -qF "$needle"; then zet_pass "$msg"; else zet_fail "$msg — '$needle' found in string"; fi
}

assert_exit_code() {
    local actual="$1" expected="$2" msg="$3"
    ZET_TESTS_RUN=$((ZET_TESTS_RUN + 1))
    if [ "$actual" -eq "$expected" ]; then zet_pass "$msg"; else zet_fail "$msg — expected exit $expected, got $actual"; fi
}

assert_equals() {
    local actual="$1" expected="$2" msg="$3"
    ZET_TESTS_RUN=$((ZET_TESTS_RUN + 1))
    if [ "$actual" = "$expected" ]; then zet_pass "$msg"; else zet_fail "$msg — expected '$expected', got '$actual'"; fi
}

assert_not_empty() {
    local value="$1" msg="$2"
    ZET_TESTS_RUN=$((ZET_TESTS_RUN + 1))
    if [ -n "$value" ]; then zet_pass "$msg"; else zet_fail "$msg — value is empty"; fi
}

assert_json_valid() {
    local output="$1" msg="$2"
    ZET_TESTS_RUN=$((ZET_TESTS_RUN + 1))
    if echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
        zet_pass "$msg"
    else
        zet_fail "$msg — invalid JSON"
    fi
}

# --- Results ---

zet_test_results() {
    echo ""
    echo "=== Results ==="
    echo "  Total: $ZET_TESTS_RUN | Passed: $ZET_TESTS_PASSED | Failed: $ZET_TESTS_FAILED"
    if [ "$ZET_TESTS_FAILED" -gt 0 ]; then
        echo ""
        echo "  Failures:"
        printf "$ZET_FAILURES\n"
        exit 1
    fi
    echo "  All tests passed."
    exit 0
}
