#!/bin/bash
# Shell script to run pgTAP tests for pcst_fast extension
# Similar to pgRouting's test runner

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default database connection settings
PGTAP_DB="${PGDATABASE:-testdb}"
PGTAP_USER="${PGUSER:-postgres}"
PGTAP_HOST="${PGHOST:-localhost}"
PGTAP_PORT="${PGPORT:-5432}"

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$SCRIPT_DIR/pgtap"

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if PostgreSQL is accessible
check_postgres() {
    print_info "Checking PostgreSQL connection..."
    if ! psql -h "$PGTAP_HOST" -p "$PGTAP_PORT" -U "$PGTAP_USER" -d "$PGTAP_DB" -c "SELECT 1;" > /dev/null 2>&1; then
        print_error "Cannot connect to PostgreSQL database:"
        print_error "  Host: $PGTAP_HOST"
        print_error "  Port: $PGTAP_PORT"
        print_error "  User: $PGTAP_USER"
        print_error "  Database: $PGTAP_DB"
        print_error ""
        print_error "Please check your connection settings or set environment variables:"
        print_error "  PGDATABASE, PGUSER, PGHOST, PGPORT"
        exit 1
    fi
    print_info "PostgreSQL connection successful"
}

# Function to check if pgTAP is installed
check_pgtap() {
    print_info "Checking for pgTAP extension..."
    if ! psql -h "$PGTAP_HOST" -p "$PGTAP_PORT" -U "$PGTAP_USER" -d "$PGTAP_DB" -c "SELECT 1 FROM pg_extension WHERE extname = 'pgtap';" | grep -q "1"; then
        print_warn "pgTAP extension not found. Attempting to install..."
        if psql -h "$PGTAP_HOST" -p "$PGTAP_PORT" -U "$PGTAP_USER" -d "$PGTAP_DB" -c "CREATE EXTENSION IF NOT EXISTS pgtap;" > /dev/null 2>&1; then
            print_info "pgTAP extension installed successfully"
        else
            print_error "Failed to install pgTAP extension."
            print_error "Please install it manually:"
            print_error "  CREATE EXTENSION pgtap;"
            print_error ""
            print_error "Or install via package manager:"
            print_error "  sudo apt-get install postgresql-XX-pgtap"
            exit 1
        fi
    else
        print_info "pgTAP extension is installed"
    fi
}

# Function to check if pcst_fast extension is installed
check_extension() {
    print_info "Checking for pcst_fast extension..."
    if ! psql -h "$PGTAP_HOST" -p "$PGTAP_PORT" -U "$PGTAP_USER" -d "$PGTAP_DB" -c "SELECT 1 FROM pg_extension WHERE extname = 'pcst_fast';" | grep -q "1"; then
        print_error "pcst_fast extension is not installed."
        print_error "Please install it first:"
        print_error "  cd $PROJECT_ROOT"
        print_error "  make install"
        print_error "  psql -d $PGTAP_DB -c 'CREATE EXTENSION pcst_fast;'"
        exit 1
    fi
    print_info "pcst_fast extension is installed"
}

# Function to run tests
run_tests() {
    print_info "Running pgTAP tests..."
    print_info "Test directory: $TEST_DIR"
    print_info ""

    # Find all test files
    test_files=$(find "$TEST_DIR" -name "*.sql" -type f | sort)

    if [ -z "$test_files" ]; then
        print_error "No test files found in $TEST_DIR"
        exit 1
    fi

    # Run each test file
    total_tests=0
    passed_tests=0
    failed_tests=0
    all_failed_tests=""
    all_outputs=""

    for test_file in $test_files; do
        test_name=$(basename "$test_file")
        print_info "Running test: $test_name"

        # Run the test and capture output
        output=$(psql -h "$PGTAP_HOST" -p "$PGTAP_PORT" -U "$PGTAP_USER" -d "$PGTAP_DB" -f "$test_file" 2>&1)
        psql_exit_code=$?

        # Extract failed tests from this output and add to summary
        failed_lines=$(echo "$output" | grep -E "^[[:space:]]*not ok" 2>/dev/null || true)
        if [ -n "$failed_lines" ]; then
            while IFS= read -r line; do
                # Extract test number and name: "not ok 6 - test name"
                clean_line=$(echo "$line" | sed 's/^[[:space:]]*//')
                test_info=$(echo "$clean_line" | sed -n 's/^not ok[[:space:]]*\([0-9]*\)[[:space:]]*-[[:space:]]*\(.*\)/\1: \2/p')
                if [ -n "$test_info" ]; then
                    all_failed_tests="${all_failed_tests}  ✗ $test_name - Test $test_info"$'\n'
                else
                    remainder=$(echo "$clean_line" | sed 's/^not ok[[:space:]]*//')
                    all_failed_tests="${all_failed_tests}  ✗ $test_name - $remainder"$'\n'
                fi
            done <<< "$failed_lines"
        fi

        # Store output with test name prefix for later extraction (fallback)
        all_outputs="${all_outputs}=== $test_name ==="$'\n'"${output}"$'\n'

        # Parse pgTAP summary line: "# Looks like you failed X tests of Y"
        # This is the most reliable way to get test counts
        tap_summary=$(echo "$output" | grep -E "# Looks like you" | head -1)

        if [ -n "$tap_summary" ]; then
            # Extract numbers from summary: "failed X tests of Y"
            failed_from_summary=$(echo "$tap_summary" | sed -n 's/.*failed \([0-9]*\) test.*/\1/p')
            total_from_summary=$(echo "$tap_summary" | sed -n 's/.*tests of \([0-9]*\)/\1/p')

            if [ -n "$failed_from_summary" ] && [ -n "$total_from_summary" ]; then
                fail_count=${failed_from_summary:-0}
                test_count=${total_from_summary:-0}
                passed_count=$((test_count - fail_count))
            else
                # Fallback: count individual test lines
                passed_count=$(echo "$output" | grep -E "^ok[[:space:]]+[0-9]" 2>/dev/null | wc -l | tr -d ' ')
                fail_count=$(echo "$output" | grep -E "^not ok[[:space:]]+[0-9]" 2>/dev/null | wc -l | tr -d ' ')
                test_count=$((passed_count + fail_count))
            fi
        else
            # No summary line found, count individual test lines
            passed_count=$(echo "$output" | grep -E "^ok[[:space:]]+[0-9]" 2>/dev/null | wc -l | tr -d ' ')
            fail_count=$(echo "$output" | grep -E "^not ok[[:space:]]+[0-9]" 2>/dev/null | wc -l | tr -d ' ')
            test_count=$((passed_count + fail_count))
        fi

        # Check for ERROR messages that indicate test failures (transaction aborted)
        error_count=$(echo "$output" | grep -c "ERROR:" 2>/dev/null || true)
        transaction_aborted=$(echo "$output" | grep -c "current transaction is aborted" 2>/dev/null || true)

        # Default to 0 if empty
        passed_count=${passed_count:-0}
        fail_count=${fail_count:-0}
        test_count=${test_count:-0}
        error_count=${error_count:-0}
        transaction_aborted=${transaction_aborted:-0}

        # If we see transaction aborted errors, there was a failure that aborted the transaction
        # Count the first error as a failure (subsequent ones are just cascading)
        if [ "$transaction_aborted" -gt 0 ]; then
            # There was at least one real failure before the transaction aborted
            # The first ERROR before "current transaction is aborted" is the real failure
            real_errors=$((error_count - transaction_aborted))
            if [ "$real_errors" -gt 0 ]; then
                fail_count=$((fail_count + 1))
            else
                # If all errors are transaction aborted, there was still a failure
                fail_count=$((fail_count + 1))
            fi
        fi

        # Add to totals (test_count already calculated above)
        total_tests=$((total_tests + test_count))
        passed_tests=$((passed_tests + passed_count))
        failed_tests=$((failed_tests + fail_count))

        # Extract failed test names for display
        # Try multiple patterns to catch all variations
        failed_test_lines=$(echo "$output" | grep -E "^not ok[[:space:]]+[0-9]" 2>/dev/null || true)
        # Fallback: if no matches, try without requiring space after "ok"
        if [ -z "$failed_test_lines" ]; then
            failed_test_lines=$(echo "$output" | grep -E "^not ok" 2>/dev/null || true)
        fi

        # Show output
        echo "$output"

        if [ "$fail_count" -eq 0 ] && [ "$transaction_aborted" -eq 0 ]; then
            print_info "✓ $test_name: All tests passed"
        else
            if [ "$transaction_aborted" -gt 0 ]; then
                print_error "✗ $test_name: Test failed and aborted transaction ($fail_count test(s) failed, $transaction_aborted cascading errors)"
            else
                print_error "✗ $test_name: $fail_count test(s) failed"
            fi

            # Show which tests failed
            if [ -n "$failed_test_lines" ]; then
                echo ""
                echo "Failed tests:"
                # Process failed tests and collect for summary
                while IFS= read -r line; do
                    # Extract test number and name: "not ok 6 - test name"
                    test_info=$(echo "$line" | sed -n 's/^not ok[[:space:]]*\([0-9]*\)[[:space:]]*-[[:space:]]*\(.*\)/\1: \2/p')
                    if [ -n "$test_info" ]; then
                        echo "  ✗ $test_info"
                        # Add to summary list (using process substitution to avoid subshell)
                        all_failed_tests="${all_failed_tests}  ✗ $test_name - Test $test_info"$'\n'
                    else
                        echo "  ✗ $line"
                        all_failed_tests="${all_failed_tests}  ✗ $test_name - $line"$'\n'
                    fi
                done <<< "$failed_test_lines"
            fi
        fi
        echo ""
    done

    # Summary
    echo "=========================================="
    if [ "$failed_tests" -eq 0 ]; then
        print_info "All tests passed! ($total_tests tests)"
        return 0
    else
        print_error "Some tests failed:"
        print_error "  Total: $total_tests"
        print_error "  Passed: $passed_tests"
        print_error "  Failed: $failed_tests"
        echo ""

        # Display failed test details
        print_error "Failed test details:"
        if [ -n "$all_failed_tests" ]; then
            # Use the directly collected failed tests (most reliable)
            printf '%s' "$all_failed_tests"
        elif [ -n "$all_outputs" ]; then
            # Fallback: extract from stored outputs
            temp_file=$(mktemp)
            printf '%s' "$all_outputs" > "$temp_file"

            current_test=""
            while IFS= read -r line || [ -n "$line" ]; do
                # Check if this is a test file separator
                if echo "$line" | grep -q "^==="; then
                    current_test=$(echo "$line" | sed 's/^=== \(.*\) ===$/\1/')
                # Check if this is a failed test line
                elif echo "$line" | grep -qE "^[[:space:]]*not ok"; then
                    # Extract test number and name: "not ok 6 - test name"
                    clean_line=$(echo "$line" | sed 's/^[[:space:]]*//')
                    test_info=$(echo "$clean_line" | sed -n 's/^not ok[[:space:]]*\([0-9]*\)[[:space:]]*-[[:space:]]*\(.*\)/\1: \2/p')
                    if [ -n "$test_info" ] && [ -n "$current_test" ]; then
                        echo "  ✗ $current_test - Test $test_info"
                    elif [ -n "$current_test" ]; then
                        remainder=$(echo "$clean_line" | sed 's/^not ok[[:space:]]*//')
                        echo "  ✗ $current_test - $remainder"
                    else
                        echo "  ✗ $clean_line"
                    fi
                fi
            done < "$temp_file"
            rm -f "$temp_file"
        else
            print_error "  (Unable to extract test names - check output above for 'not ok' lines)"
        fi
        return 1
    fi
}

# Main execution
main() {
    echo "=========================================="
    echo "pgTAP Test Runner for pcst_fast Extension"
    echo "=========================================="
    echo ""
    echo "Database: $PGTAP_DB"
    echo "User: $PGTAP_USER"
    echo "Host: $PGTAP_HOST"
    echo "Port: $PGTAP_PORT"
    echo ""

    check_postgres
    check_pgtap
    check_extension
    echo ""

    if run_tests; then
        exit 0
    else
        exit 1
    fi
}

# Handle command line arguments
case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [options]"
        echo ""
        echo "Run pgTAP tests for pcst_fast extension"
        echo ""
        echo "Environment variables:"
        echo "  PGDATABASE  Database name (default: postgres)"
        echo "  PGUSER      Database user (default: postgres)"
        echo "  PGHOST      Database host (default: localhost)"
        echo "  PGPORT      Database port (default: 5432)"
        echo ""
        echo "Examples:"
        echo "  $0"
        echo "  PGDATABASE=mydb PGUSER=myuser $0"
        exit 0
        ;;
    *)
        main
        ;;
esac

