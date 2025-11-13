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