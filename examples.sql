-- Example usage of pg_pcst_fast extension
-- Run these commands after installing the extension

-- Create the extension
CREATE EXTENSION IF NOT EXISTS pcst_fast;

-- Example 1: Simple linear graph
-- Graph: 0---1---2---3 with prizes and costs
SELECT 'Example 1: Linear graph' as description;
SELECT * FROM pcst_fast(
    ARRAY[[0,1],[1,2],[2,3]],                    -- Linear chain of edges
    ARRAY[50.0, 10.0, 15.0, 40.0]::float8[],    -- Node prizes
    ARRAY[5.0, 8.0, 12.0]::float8[],             -- Edge costs
    -1,                                           -- Auto-select root
    1,                                            -- Single cluster
    'strong',                                     -- Strong pruning
    0                                             -- Minimal verbosity
);

-- Example 2: Complex network
-- More realistic network with 8 nodes
SELECT 'Example 2: Complex network' as description;
SELECT * FROM pcst_fast(
    ARRAY[
        [0,1], [0,2], [1,3], [1,4],
        [2,5], [2,6], [3,7], [4,7],
        [5,6], [6,7], [0,3], [2,4]
    ],
    ARRAY[50.0, 10.0, 15.0, 45.0, 12.0, 8.0, 20.0, 40.0]::float8[],
    ARRAY[5.0, 8.0, 12.0, 7.0, 6.0, 9.0, 15.0, 11.0, 4.0, 8.0, 20.0, 25.0]::float8[],
    -1,      -- Auto-select root
    1,       -- Single cluster
    'strong', -- Strong pruning
    0        -- Minimal verbosity
);

-- Example 3: Compare different pruning methods
SELECT 'Example 3: Different pruning methods' as description;

-- No pruning
SELECT 'No pruning' as method, * FROM pcst_fast(
    ARRAY[[0,1],[1,2],[2,3],[3,4]],
    ARRAY[30.0, 20.0, 25.0, 35.0, 40.0]::float8[],
    ARRAY[10.0, 8.0, 12.0, 15.0]::float8[],
    0, 1, 'none', 0
);

-- Strong pruning
SELECT 'Strong pruning' as method, * FROM pcst_fast(
    ARRAY[[0,1],[1,2],[2,3],[3,4]],
    ARRAY[30.0, 20.0, 25.0, 35.0, 40.0]::float8[],
    ARRAY[10.0, 8.0, 12.0, 15.0]::float8[],
    0, 1, 'strong', 0
);

-- Example 4: pg_routing-style function with SQL queries
-- This example shows how to use the new pgr_pcst_fast function
-- that accepts SQL queries for edges and nodes
SELECT 'Example 4: pg_routing-style function' as description;

-- Create temporary tables for demonstration
CREATE TEMP TABLE IF NOT EXISTS demo_edges (
    id integer,
    source integer,
    target integer,
    cost float8
);

CREATE TEMP TABLE IF NOT EXISTS demo_nodes (
    id integer,
    prize float8
);

-- Insert sample data
INSERT INTO demo_edges (id, source, target, cost) VALUES
    (1, 100, 101, 5.0),
    (2, 101, 102, 8.0),
    (3, 102, 103, 12.0),
    (4, 100, 102, 20.0);

INSERT INTO demo_nodes (id, prize) VALUES
    (100, 50.0),
    (101, 10.0),
    (102, 15.0),
    (103, 40.0);

-- Use the pg_routing-style function
-- Note: The function automatically maps between original IDs (100, 101, etc.)
-- and internal indices (0, 1, etc.), and maps results back to original IDs
-- Returns one row per selected edge in pg_routing format
SELECT * FROM pgr_pcst_fast(
    'SELECT id, source, target, cost FROM demo_edges',
    'SELECT id, prize FROM demo_nodes',
    100,  -- Root node ID (original ID, not index)
    1,    -- Single cluster
    'simple',  -- Pruning method
    0     -- Verbosity
);

-- Example 5: Visualization of pg_routing-style function results
-- This is useful for debugging and understanding the algorithm results
SELECT 'Example 5: Visualization of pg_routing-style function' as description;
SELECT pgr_pcst_fast_with_viz(
    'SELECT id, source, target, cost FROM demo_edges',
    'SELECT id, prize FROM demo_nodes',
    -1,  -- Root node ID (auto-select)
    1,    -- Single cluster
    'gw',  -- Pruning method
    0     -- Verbosity
);

-- Example 6: Test with original array-based function to compare
-- This tests the same data using 0-based indices to see if the issue is
-- with the pgr function or the algorithm itself
SELECT 'Example 6: Same data with array-based function' as description;
-- Convert IDs: 100->0, 101->1, 102->2, 103->3
SELECT * FROM pcst_fast(
    ARRAY[[0,1], [1,2], [2,3], [0,2]],  -- Same edges, 0-based
    ARRAY[50.0, 10.0, 15.0, 40.0]::float8[],  -- Same prizes
    ARRAY[1.0, 1.0, 1.0, 1.0]::float8[],  -- All costs = 1
    -1,  -- Auto-select root
    1,   -- Single cluster
    'gw',  -- Same pruning
    0    -- Verbosity
);