-- pgTAP tests for pgr_pcst_fast function
-- Similar to pgRouting test structure

BEGIN;

-- Load pgTAP
SELECT plan(30);

-- Test 1: Extension is installed
SELECT has_extension('pcst_fast', 'Extension pcst_fast should be installed');

-- Test 2: Function exists
SELECT has_function(
    'public',
    'pgr_pcst_fast',
    ARRAY['text', 'text', 'text', 'integer', 'text', 'integer'],
    'Function pgr_pcst_fast should exist'
);

-- Note: function_returns can't be used with TABLE types, we'll verify structure in Test 5

-- Create test tables
CREATE TABLE IF NOT EXISTS test_edges (
    id INTEGER,
    source INTEGER,
    target INTEGER,
    cost FLOAT8
);

CREATE TABLE IF NOT EXISTS test_nodes (
    id INTEGER,
    prize FLOAT8
);

-- Clean up any existing data
TRUNCATE TABLE test_edges;
TRUNCATE TABLE test_nodes;

-- Insert test data: linear graph with some nodes without prizes
-- Graph: 100 -> 101 -> 102 -> 103
-- Node 100 has no prize (defaults to 0)
-- Nodes 101, 102, 103 have prizes
INSERT INTO test_edges (id, source, target, cost) VALUES
    (1, 100, 101, 5.0),
    (2, 101, 102, 8.0),
    (3, 102, 103, 12.0);

INSERT INTO test_nodes (id, prize) VALUES
    (101, 10.0),
    (102, 15.0),
    (103, 40.0);

-- Test 3: Basic function call with integer IDs
SELECT lives_ok(
    $$SELECT * FROM pgr_pcst_fast(
        'SELECT id::text, source::text, target::text, cost FROM test_edges',
        'SELECT id::text, prize FROM test_nodes',
        NULL,
        1,
        'gw',
        0
    )$$,
    'Function should execute without error with integer IDs'
);

-- Test 4: Function returns results
SELECT ok(
    (SELECT COUNT(*) > 0 FROM pgr_pcst_fast(
        'SELECT id::text, source::text, target::text, cost FROM test_edges',
        'SELECT id::text, prize FROM test_nodes',
        NULL,
        1,
        'gw',
        0
    )),
    'Function should return at least one row'
);

-- Test 5: Results have correct columns
SELECT lives_ok(
    $$SELECT seq, edge, source, target, cost FROM pgr_pcst_fast(
        'SELECT id::text, source::text, target::text, cost FROM test_edges',
        'SELECT id::text, prize FROM test_nodes',
        NULL,
        1,
        'gw',
        0
    ) LIMIT 1$$,
    'Results should have correct column structure (seq, edge, source, target, cost)'
);

-- Test 6: Root node specification works (root in middle of linear graph)
SELECT lives_ok(
    $$SELECT * FROM pgr_pcst_fast(
        'SELECT id::text, source::text, target::text, cost FROM test_edges',
        'SELECT id::text, prize FROM test_nodes',
        '102',
        1,
        'gw',
        0
    )$$,
    'Function should work with root node specified in middle of graph'
);

-- Test 7: Auto-select root (NULL) works
SELECT lives_ok(
    $$SELECT * FROM pgr_pcst_fast(
        'SELECT id::text, source::text, target::text, cost FROM test_edges',
        'SELECT id::text, prize FROM test_nodes',
        NULL,
        1,
        'gw',
        0
    )$$,
    'Function should work with auto-select root (NULL)'
);

-- Test 8: Root node at start of graph (node without prize)
SELECT lives_ok(
    $$SELECT * FROM pgr_pcst_fast(
        'SELECT id::text, source::text, target::text, cost FROM test_edges',
        'SELECT id::text, prize FROM test_nodes',
        '100',
        1,
        'gw',
        0
    )$$,
    'Function should work with root node at start (node without prize, defaults to 0)'
);

-- Test 9: Root node at end of graph
SELECT lives_ok(
    $$SELECT * FROM pgr_pcst_fast(
        'SELECT id::text, source::text, target::text, cost FROM test_edges',
        'SELECT id::text, prize FROM test_nodes',
        '103',
        1,
        'gw',
        0
    )$$,
    'Function should work with root node at end of graph'
);

-- Test 10: Root node in middle should execute without error and return results
-- This test will fail if the function throws an error (like "PCST algorithm failed")
SELECT lives_ok(
    $$SELECT COUNT(*) FROM pgr_pcst_fast(
        'SELECT id::text, source::text, target::text, cost FROM test_edges',
        'SELECT id::text, prize FROM test_nodes',
        '102',
        1,
        'gw',
        0
    )$$,
    'Root node in middle should execute without error'
);

-- Helper function to safely test a query that might fail
CREATE OR REPLACE FUNCTION safe_test_count(test_query TEXT)
RETURNS INTEGER AS $$
DECLARE
    result_count INTEGER;
BEGIN
    EXECUTE format('SELECT COUNT(*) FROM (%s) t', test_query) INTO result_count;
    RETURN result_count;
EXCEPTION WHEN OTHERS THEN
    -- Return -1 to indicate error occurred
    RETURN -1;
END;
$$ LANGUAGE plpgsql;

-- Test 11: Verify root node in middle actually returns results
DO $outer$
DECLARE
    result_count INTEGER;
BEGIN
    result_count := safe_test_count($inner$SELECT * FROM pgr_pcst_fast(
        'SELECT id::text, source::text, target::text, cost FROM test_edges',
        'SELECT id::text, prize FROM test_nodes',
        '102',
        1,
        'gw',
        0
    )$inner$);

    IF result_count = -1 THEN
        PERFORM ok(FALSE, 'Root node in middle should return results - Function threw an error');
    ELSIF result_count > 0 THEN
        PERFORM ok(TRUE, 'Root node in middle should return results');
    ELSE
        PERFORM ok(FALSE, 'Root node in middle should return results - No results returned');
    END IF;
END $outer$;

-- Test 12: Root node without prize should execute without error
SELECT lives_ok(
    $$SELECT COUNT(*) FROM pgr_pcst_fast(
        'SELECT id::text, source::text, target::text, cost FROM test_edges',
        'SELECT id::text, prize FROM test_nodes',
        '100',
        1,
        'gw',
        0
    )$$,
    'Root node without prize should execute without error'
);

-- Test 13: Root node without prize actually returns results
DO $outer2$
DECLARE
    result_count INTEGER;
BEGIN
    result_count := safe_test_count($inner2$SELECT * FROM pgr_pcst_fast(
        'SELECT id::text, source::text, target::text, cost FROM test_edges',
        'SELECT id::text, prize FROM test_nodes',
        '100',
        1,
        'gw',
        0
    )$inner2$);

    IF result_count = -1 THEN
        PERFORM ok(FALSE, 'Root node without prize should return results - Function threw an error');
    ELSIF result_count > 0 THEN
        PERFORM ok(TRUE, 'Root node without prize (defaults to 0) should return results');
    ELSE
        PERFORM ok(FALSE, 'Root node without prize should return results - No results returned');
    END IF;
END $outer2$;

-- Test 14: Text-based IDs work
CREATE TABLE IF NOT EXISTS test_edges_text (
    id TEXT,
    source TEXT,
    target TEXT,
    cost FLOAT8
);

CREATE TABLE IF NOT EXISTS test_nodes_text (
    id TEXT,
    prize FLOAT8
);

TRUNCATE TABLE test_edges_text;
TRUNCATE TABLE test_nodes_text;

INSERT INTO test_edges_text (id, source, target, cost) VALUES
    ('e1', 'n1', 'n2', 1.0),
    ('e2', 'n2', 'n3', 1.0),
    ('e3', 'n3', 'n1', 1.0);

INSERT INTO test_nodes_text (id, prize) VALUES
    ('n1', 10.0),
    ('n2', 20.0),
    ('n3', 30.0);

SELECT lives_ok(
    $$SELECT * FROM pgr_pcst_fast(
        'SELECT id, source, target, cost FROM test_edges_text',
        'SELECT id, prize FROM test_nodes_text',
        NULL,
        1,
        'gw',
        0
    )$$,
    'Function should work with text-based IDs'
);

-- Test 15: Pruning method "none" works
SELECT lives_ok(
    $$SELECT * FROM pgr_pcst_fast(
        'SELECT id::text, source::text, target::text, cost FROM test_edges',
        'SELECT id::text, prize FROM test_nodes',
        NULL,
        1,
        'none',
        0
    )$$,
    'Function should work with pruning method "none"'
);

-- Test 16: Pruning method "gw" works
SELECT lives_ok(
    $$SELECT * FROM pgr_pcst_fast(
        'SELECT id::text, source::text, target::text, cost FROM test_edges',
        'SELECT id::text, prize FROM test_nodes',
        NULL,
        1,
        'gw',
        0
    )$$,
    'Function should work with pruning method "gw"'
);

-- Test 17: Pruning method "gw" works
SELECT lives_ok(
    $$SELECT * FROM pgr_pcst_fast(
        'SELECT id::text, source::text, target::text, cost FROM test_edges',
        'SELECT id::text, prize FROM test_nodes',
        NULL,
        1,
        'gw',
        0
    )$$,
    'Function should work with pruning method "gw"'
);

-- Test 18: Pruning method "strong" works
SELECT lives_ok(
    $$SELECT * FROM pgr_pcst_fast(
        'SELECT id::text, source::text, target::text, cost FROM test_edges',
        'SELECT id::text, prize FROM test_nodes',
        NULL,
        1,
        'strong',
        0
    )$$,
    'Function should work with pruning method "strong"'
);

-- Test 19: Multiple clusters work
SELECT lives_ok(
    $$SELECT * FROM pgr_pcst_fast(
        'SELECT id::text, source::text, target::text, cost FROM test_edges',
        'SELECT id::text, prize FROM test_nodes',
        NULL,
        2,
        'gw',
        0
    )$$,
    'Function should work with multiple clusters'
);

-- Test 20: Verbosity levels work
SELECT lives_ok(
    $$SELECT * FROM pgr_pcst_fast(
        'SELECT id::text, source::text, target::text, cost FROM test_edges',
        'SELECT id::text, prize FROM test_nodes',
        NULL,
        1,
        'gw',
        1
    )$$,
    'Function should work with verbosity=1'
);

-- Test 21: Empty edges query should handle gracefully
SELECT throws_ok(
    $$SELECT * FROM pgr_pcst_fast(
        'SELECT id::text, source::text, target::text, cost FROM test_edges WHERE 1=0',
        'SELECT id::text, prize FROM test_nodes',
        NULL,
        1,
        'gw',
        0
    )$$,
    NULL,
    'Function should handle empty edges query'
);

-- Test 22: Empty nodes query should work (all prizes default to 0)
SELECT lives_ok(
    $$SELECT * FROM pgr_pcst_fast(
        'SELECT id::text, source::text, target::text, cost FROM test_edges',
        'SELECT id::text, prize FROM test_nodes WHERE 1=0',
        NULL,
        1,
        'gw',
        0
    )$$,
    'Function should work with empty nodes query (prizes default to 0)'
);

-- Test 23: Node not in edges is handled (should not crash)
SELECT lives_ok(
    $outer$SELECT * FROM pgr_pcst_fast(
        'SELECT id::text, source::text, target::text, cost FROM test_edges',
        $inner$SELECT id::text, prize FROM test_nodes
         UNION ALL
         SELECT '999'::text, 100.0::float8$inner$,
        NULL,
        1,
        'gw',
        0
    )$outer$,
    'Function should handle nodes not in edges gracefully'
);

-- Test 24: Results have seq column starting at 1
SELECT ok(
    (SELECT MIN(seq) = 1 FROM pgr_pcst_fast(
        'SELECT id::text, source::text, target::text, cost FROM test_edges',
        'SELECT id::text, prize FROM test_nodes',
        NULL,
        1,
        'gw',
        0
    )),
    'seq column should start at 1'
);

-- Test 25: Results have non-null edge IDs
SELECT ok(
    (SELECT COUNT(*) = COUNT(edge) FROM pgr_pcst_fast(
        'SELECT id::text, source::text, target::text, cost FROM test_edges',
        'SELECT id::text, prize FROM test_nodes',
        NULL,
        1,
        'gw',
        0
    )),
    'All edge IDs should be non-null'
);

-- Test 26: Results have non-negative costs
SELECT ok(
    (SELECT COUNT(*) = 0 FROM pgr_pcst_fast(
        'SELECT id::text, source::text, target::text, cost FROM test_edges',
        'SELECT id::text, prize FROM test_nodes',
        NULL,
        1,
        'gw',
        0
    ) WHERE cost < 0),
    'All costs should be non-negative'
);

-- Test 27: Integer root_id overload works
SELECT lives_ok(
    $$SELECT * FROM pgr_pcst_fast(
        'SELECT id::text, source::text, target::text, cost FROM test_edges',
        'SELECT id::text, prize FROM test_nodes',
        102,
        1,
        'gw',
        0
    )$$,
    'Integer root_id overload should work'
);

-- Test 28: Integer root_id = -1 works (auto-select)
SELECT lives_ok(
    $$SELECT * FROM pgr_pcst_fast(
        'SELECT id::text, source::text, target::text, cost FROM test_edges',
        'SELECT id::text, prize FROM test_nodes',
        -1,
        1,
        'gw',
        0
    )$$,
    'Integer root_id = -1 should work (auto-select)'
);

-- Test 29: Root node specification with verbose output (debugging test)
-- This test specifically checks root node handling with verbosity enabled
-- to capture debug information about root node mapping and algorithm parameters
DO $test29$
DECLARE
    result_count INTEGER;
    test_passed BOOLEAN := FALSE;
    error_msg TEXT;
BEGIN
    -- Test with verbosity=1 to generate debug logs
    -- The logs should show:
    -- 1. Root node ID mapping to index
    -- 2. Root index validation (in_range, in_edges)
    -- 3. Algorithm parameters (num_edges, num_nodes, root_index, etc.)
    BEGIN
        SELECT COUNT(*) INTO result_count
        FROM pgr_pcst_fast(
            'SELECT id::text, source::text, target::text, cost FROM test_edges',
            'SELECT id::text, prize FROM test_nodes',
            '102',  -- Root node in middle
            1,
            'gw',
            1  -- verbosity=1 for debug output
        );

        IF result_count > 0 THEN
            test_passed := TRUE;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        error_msg := SQLERRM;
        RAISE NOTICE 'Test 29 failed with error: %', error_msg;
    END;

    PERFORM ok(test_passed,
        'Root node specification with verbosity should work and return results. ' ||
        'Check server logs for debug output showing: ' ||
        '1) Root node ID mapping (e.g., "Root node ID ''102'' mapped to index X"), ' ||
        '2) Root index validation (in_range=YES, in_edges=YES), ' ||
        '3) Algorithm parameters (num_edges, num_nodes, root_index, etc.)');
END;
$test29$;

-- Test 30: Root node with different pruning methods (comprehensive test)
-- Tests root node with various pruning methods to identify which combinations work
-- Note: When root is specified, num_clusters is automatically set to 0 by the algorithm
DO $test30$
DECLARE
    pruning_methods TEXT[] := ARRAY['none', 'simple', 'gw', 'strong'];
    method TEXT;
    result_count INTEGER;
    success_count INTEGER := 0;
    failed_methods TEXT := '';
BEGIN
    FOREACH method IN ARRAY pruning_methods
    LOOP
        BEGIN
            SELECT COUNT(*) INTO result_count
            FROM pgr_pcst_fast(
                'SELECT id::text, source::text, target::text, cost FROM test_edges',
                'SELECT id::text, prize FROM test_nodes',
                '101',  -- Root node (num_clusters will be auto-set to 0 internally)
                1,      -- User-specified num_clusters (ignored when root is specified)
                method,
                0
            );

            IF result_count > 0 THEN
                success_count := success_count + 1;
            ELSE
                failed_methods := failed_methods || method || ' (no results) ';
            END IF;
        EXCEPTION WHEN OTHERS THEN
            failed_methods := failed_methods || method || ' (error: ' || SQLERRM || ') ';
        END;
    END LOOP;

    PERFORM ok(success_count > 0,
        format('Root node should work with at least one pruning method. ' ||
                'Success: %s/%s methods. Failed: %s',
                success_count::text, array_length(pruning_methods, 1)::text,
                COALESCE(NULLIF(failed_methods, ''), 'none')));
END;
$test30$;

-- Clean up
DROP TABLE IF EXISTS test_edges;
DROP TABLE IF EXISTS test_nodes;
DROP TABLE IF EXISTS test_edges_text;
DROP TABLE IF EXISTS test_nodes_text;

-- Test Summary: Root Node Debugging
-- ===================================
-- When running tests with verbosity=1, check PostgreSQL server logs for:
--
-- 1. ROOT NODE MAPPING:
--    Look for: "pgr_pcst_fast: Root node ID 'X' mapped to index Y (num_nodes=Z)"
--    This confirms the root node ID was successfully found and mapped to an internal index.
--
-- 2. ROOT INDEX VALIDATION:
--    Look for: "pgr_pcst_fast: Root index X validation: in_range=YES/NO, in_edges=YES/NO"
--    This shows:
--    - in_range: Whether root_index is in valid range [0, num_nodes-1]
--    - in_edges: Whether root_index appears in at least one edge
--
-- 3. ALGORITHM PARAMETERS:
--    Look for: "pgr_pcst_fast: Calling pcst_solve with: num_edges=X, num_nodes=Y, root_index=Z, ..."
--    This shows all parameters being passed to the underlying algorithm.
--
-- 4. ALGORITHM FAILURE DETAILS:
--    If "PCST algorithm failed" error occurs, the error message will include:
--    - root index value
--    - number of clusters
--    - pruning method
--    - number of nodes and edges
--
-- EXPECTED BEHAVIOR:
-- - Root node should map to a valid index (0 <= index < num_nodes)
-- - Root index should appear in at least one edge (in_edges=YES)
-- - Algorithm should succeed with valid root node specification
--
-- KNOWN ISSUES:
-- - Root nodes with 'gw' pruning may fail (see README.md)
-- - If 'gw' fails, try 'strong' pruning as an alternative

SELECT finish();

ROLLBACK;

