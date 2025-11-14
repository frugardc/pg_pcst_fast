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
-- Note: root_id accepts text or NULL. Integers will be automatically cast to text.
SELECT * FROM pgr_pcst_fast(
    'SELECT id, source, target, cost FROM demo_edges',
    'SELECT id, prize FROM demo_nodes',
    '100',  -- Root node ID (as text, or pass integer which will be cast)
    1,      -- Single cluster
    'simple',  -- Pruning method
    0       -- Verbosity
);

-- Example 5: Visualization of pg_routing-style function results
-- This is useful for debugging and understanding the algorithm results
SELECT 'Example 5: Visualization of pg_routing-style function' as description;
SELECT pgr_pcst_fast_with_viz(
    'SELECT id, source, target, cost FROM demo_edges',
    'SELECT id, prize FROM demo_nodes',
    NULL,  -- Root node ID (NULL for auto-select, or pass integer which will be cast to text)
    1,     -- Single cluster
    'gw',  -- Pruning method
    0      -- Verbosity
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

-- ============================================================================
-- TEXT-BASED ID EXAMPLES
-- ============================================================================
-- The pgr_pcst_fast function now supports both integer and text IDs.
-- Text IDs are automatically converted internally, and results are returned as text.
-- ============================================================================

-- Example 7: Text-based node and edge IDs
-- Using location codes or city names as IDs
SELECT 'Example 7: Text-based IDs (location codes)' as description;

CREATE TEMP TABLE IF NOT EXISTS location_edges (
    id text,
    source text,
    target text,
    cost float8
);

CREATE TEMP TABLE IF NOT EXISTS location_nodes (
    id text,
    prize float8
);

-- Insert data with text IDs (location codes)
INSERT INTO location_edges (id, source, target, cost) VALUES
    ('E1', 'NYC', 'BOS', 5.0),
    ('E2', 'BOS', 'PHL', 8.0),
    ('E3', 'PHL', 'DC', 12.0),
    ('E4', 'NYC', 'PHL', 20.0);

INSERT INTO location_nodes (id, prize) VALUES
    ('NYC', 50.0),
    ('BOS', 10.0),
    ('PHL', 15.0),
    ('DC', 40.0);

-- Use text IDs - function automatically handles them
SELECT * FROM pgr_pcst_fast(
    'SELECT id, source, target, cost FROM location_edges',
    'SELECT id, prize FROM location_nodes',
    'NYC',  -- Root node ID (text)
    1,      -- Single cluster
    'simple',
    0
);

-- Example 8: Mixed integer and text IDs (automatic conversion)
-- Shows that integers are automatically converted to text
SELECT 'Example 8: Mixed integer and text IDs' as description;

CREATE TEMP TABLE IF NOT EXISTS mixed_edges (
    id text,
    source integer,  -- Integer source
    target text,     -- Text target
    cost float8
);

CREATE TEMP TABLE IF NOT EXISTS mixed_nodes (
    id text,         -- Text ID
    prize float8
);

INSERT INTO mixed_edges (id, source, target, cost) VALUES
    ('edge_1', 100, 'node_B', 5.0),
    ('edge_2', 100, 'node_C', 8.0),
    ('edge_3', 101, 'node_D', 12.0);

INSERT INTO mixed_nodes (id, prize) VALUES
    ('100', 50.0),      -- Text representation of integer
    ('101', 20.0),
    ('node_B', 10.0),
    ('node_C', 15.0),
    ('node_D', 40.0);

-- Integers are automatically converted to text internally
SELECT * FROM pgr_pcst_fast(
    'SELECT id, source, target, cost FROM mixed_edges',
    'SELECT id, prize FROM mixed_nodes',
    '100',  -- Root as text (will match integer 100)
    1,
    'simple',
    0
);

-- Example 9: Real-world scenario with descriptive IDs
-- Network of facilities with descriptive names
SELECT 'Example 9: Facility network with descriptive IDs' as description;

CREATE TEMP TABLE IF NOT EXISTS facility_edges (
    id text,
    source text,
    target text,
    cost float8
);

CREATE TEMP TABLE IF NOT EXISTS facility_nodes (
    id text,
    prize float8
);

-- Network of facilities
INSERT INTO facility_edges (id, source, target, cost) VALUES
    ('conn_1', 'Warehouse_A', 'Distribution_Center_1', 15.0),
    ('conn_2', 'Distribution_Center_1', 'Retail_Store_1', 8.0),
    ('conn_3', 'Distribution_Center_1', 'Retail_Store_2', 12.0),
    ('conn_4', 'Warehouse_B', 'Distribution_Center_2', 10.0),
    ('conn_5', 'Distribution_Center_2', 'Retail_Store_3', 9.0),
    ('conn_6', 'Warehouse_A', 'Distribution_Center_2', 25.0),
    ('conn_7', 'Retail_Store_1', 'Retail_Store_2', 5.0);

INSERT INTO facility_nodes (id, prize) VALUES
    ('Warehouse_A', 100.0),
    ('Warehouse_B', 80.0),
    ('Distribution_Center_1', 60.0),
    ('Distribution_Center_2', 55.0),
    ('Retail_Store_1', 40.0),
    ('Retail_Store_2', 35.0),
    ('Retail_Store_3', 45.0);

-- Find optimal network connecting facilities
SELECT * FROM pgr_pcst_fast(
    'SELECT id, source, target, cost FROM facility_edges',
    'SELECT id, prize FROM facility_nodes',
    NULL,  -- Auto-select root (NULL for auto-select)
    1,
    'strong',
    0
);

-- Example 10: Casting text results back to integers (if needed)
-- Sometimes you might want to work with text IDs but need integers for joins
SELECT 'Example 10: Casting text results to integers' as description;

-- Create tables with integer IDs but query returns text
CREATE TEMP TABLE IF NOT EXISTS numeric_edges (
    id integer,
    source integer,
    target integer,
    cost float8
);

CREATE TEMP TABLE IF NOT EXISTS numeric_nodes (
    id integer,
    prize float8
);

INSERT INTO numeric_edges (id, source, target, cost) VALUES
    (1, 100, 101, 5.0),
    (2, 101, 102, 8.0),
    (3, 102, 103, 12.0);

INSERT INTO numeric_nodes (id, prize) VALUES
    (100, 50.0),
    (101, 10.0),
    (102, 15.0),
    (103, 40.0);

-- Results come back as text, but you can cast them to integers
SELECT
    seq,
    edge::integer as edge_id,
    source::integer as source_id,
    target::integer as target_id,
    cost
FROM pgr_pcst_fast(
    'SELECT id, source, target, cost FROM numeric_edges',
    'SELECT id, prize FROM numeric_nodes',
    '100',  -- Root as text (will be converted from integer)
    1,
    'simple',
    0
);

-- Example 11: UUID-style IDs
-- Using UUIDs or other unique identifiers as text
SELECT 'Example 11: UUID-style text IDs' as description;

CREATE TEMP TABLE IF NOT EXISTS uuid_edges (
    id text,
    source text,
    target text,
    cost float8
);

CREATE TEMP TABLE IF NOT EXISTS uuid_nodes (
    id text,
    prize float8
);

-- Using UUID-like identifiers
INSERT INTO uuid_edges (id, source, target, cost) VALUES
    ('550e8400-e29b-41d4-a716-446655440001', '550e8400-e29b-41d4-a716-446655440010', '550e8400-e29b-41d4-a716-446655440011', 5.0),
    ('550e8400-e29b-41d4-a716-446655440002', '550e8400-e29b-41d4-a716-446655440011', '550e8400-e29b-41d4-a716-446655440012', 8.0),
    ('550e8400-e29b-41d4-a716-446655440003', '550e8400-e29b-41d4-a716-446655440012', '550e8400-e29b-41d4-a716-446655440013', 12.0);

INSERT INTO uuid_nodes (id, prize) VALUES
    ('550e8400-e29b-41d4-a716-446655440010', 50.0),
    ('550e8400-e29b-41d4-a716-446655440011', 10.0),
    ('550e8400-e29b-41d4-a716-446655440012', 15.0),
    ('550e8400-e29b-41d4-a716-446655440013', 40.0);

-- Works seamlessly with UUID-style text IDs
SELECT * FROM pgr_pcst_fast(
    'SELECT id, source, target, cost FROM uuid_edges',
    'SELECT id, prize FROM uuid_nodes',
    '550e8400-e29b-41d4-a716-446655440010',  -- Root UUID
    1,
    'simple',
    0
);

-- Example 12: Visualization with text IDs
-- See how text IDs appear in the visualization output
SELECT 'Example 12: Visualization with text IDs' as description;
SELECT pgr_pcst_fast_with_viz(
    'SELECT id, source, target, cost FROM location_edges',
    'SELECT id, prize FROM location_nodes',
    'NYC',  -- Root as text
    1,
    'simple',
    0
);