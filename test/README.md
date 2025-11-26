# pgTAP Tests for pcst_fast Extension

This directory contains pgTAP tests for the `pcst_fast` PostgreSQL extension, following a similar structure to pgRouting's test suite.

## Prerequisites

1. **pgTAP Extension**: Install pgTAP in your PostgreSQL database:
   ```sql
   CREATE EXTENSION pgtap;
   ```

   On Ubuntu/Debian, you can install pgTAP via:
   ```bash
   sudo apt-get install postgresql-XX-pgtap
   ```
   (Replace `XX` with your PostgreSQL version number)

2. **Extension Installed**: Make sure the `pcst_fast` extension is installed:
   ```sql
   CREATE EXTENSION pcst_fast;
   ```

## Running Tests

### Using the Shell Script (Recommended)

The easiest way to run tests is using the provided shell script:

```bash
./test/run_tests.sh
```

This script will:
1. Check PostgreSQL connection
2. Check for and install pgTAP if needed
3. Verify the extension is installed
4. Run all pgTAP tests with colored output
5. Provide a summary of test results

You can customize the database connection using environment variables:

```bash
PGDATABASE=mydb PGUSER=myuser PGHOST=localhost PGPORT=5432 ./test/run_tests.sh
```

For help:
```bash
./test/run_tests.sh --help
```

### Using Make

Alternatively, you can use the Makefile:

```bash
make test
```

This will:
1. Check for and install pgTAP if needed
2. Run all pgTAP tests in `test/pgtap/`

You can customize the database connection using environment variables:

```bash
PGDATABASE=mydb PGUSER=myuser PGHOST=localhost PGPORT=5432 make test
```

### Using psql Directly

You can also run tests directly with psql:

```bash
psql -d your_database -f test/pgtap/pgr_pcst_fast.sql
```

## Test Structure

Tests are organized in the `test/pgtap/` directory:

- `pgr_pcst_fast.sql`: Tests for the `pgr_pcst_fast` function

## Test Coverage

The current test suite covers:

1. **Extension Installation**: Verifies the extension is installed
2. **Function Existence**: Checks that functions exist with correct signatures
3. **Basic Functionality**: Tests basic function calls with various parameters
4. **ID Types**: Tests both integer and text-based IDs
5. **Pruning Methods**: Tests all pruning methods (none, simple, gw, strong)
6. **Root Node Handling**: Tests root node specification and auto-select
7. **Edge Cases**: Tests empty queries, missing nodes, etc.
8. **Result Structure**: Verifies correct column structure and data types

## Adding New Tests

To add new tests:

1. Create or edit a test file in `test/pgtap/`
2. Follow the pgTAP test structure:
   ```sql
   BEGIN;
   SELECT plan(N);  -- Number of tests

   -- Your tests here
   SELECT ok(...);
   SELECT lives_ok(...);
   -- etc.

   SELECT finish();
   ROLLBACK;
   ```

3. Run the tests to verify they pass

## Test Best Practices

- Use `BEGIN`/`ROLLBACK` to isolate test data
- Clean up test tables after each test
- Use descriptive test names
- Test both success and failure cases
- Test edge cases (empty results, NULL values, etc.)

## Troubleshooting

### Tests Fail with "Extension pgtap does not exist"

Install pgTAP:
```sql
CREATE EXTENSION pgtap;
```

### Tests Fail with "Extension pcst_fast does not exist"

Install the extension:
```bash
make install
psql -d your_database -c "CREATE EXTENSION pcst_fast;"
```

### Connection Errors

Make sure your PostgreSQL connection settings are correct:
- Check `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE` environment variables
- Or modify the Makefile variables: `PGTAP_DB`, `PGTAP_USER`, `PGTAP_HOST`, `PGTAP_PORT`

## References

- [pgTAP Documentation](https://pgtap.org/)
- [pgRouting Tests](https://github.com/pgRouting/pgrouting/tree/main/test) (for reference)

