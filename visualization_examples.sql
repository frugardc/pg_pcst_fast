-- ASCII Visualization Examples for PCST Fast Extension

-- Example 1: Simple linear graph with visualization
SELECT 'Example 1: Linear graph visualization' as description;
SELECT pcst_fast_with_viz(
    ARRAY[[0,1], [1,2], [2,3]],
    ARRAY[100.0, 20.0, 30.0, 80.0]::float8[],
    ARRAY[5.0, 10.0, 15.0]::float8[]
);

-- Example 2: Star graph (one central node connected to others)
SELECT 'Example 2: Star graph visualization' as description;
SELECT pcst_fast_with_viz(
    ARRAY[[0,1], [0,2], [0,3], [0,4]],
    ARRAY[50.0, 100.0, 80.0, 60.0, 90.0]::float8[],
    ARRAY[10.0, 12.0, 8.0, 15.0]::float8[]
);

-- Example 3: More complex network with multiple clusters
SELECT 'Example 3: Complex network visualization' as description;
SELECT pcst_fast_with_viz(
    ARRAY[[0,1], [1,2], [3,4], [4,5], [6,7]],  -- Three separate components
    ARRAY[100.0, 50.0, 75.0, 200.0, 60.0, 80.0, 150.0, 40.0]::float8[],
    ARRAY[20.0, 25.0, 30.0, 22.0, 35.0]::float8[],
    -1, 3, 'simple'  -- Allow 3 clusters
);

-- Example 4: Using the separate functions for more control
SELECT 'Example 4: Step-by-step visualization' as description;

-- First run PCST
WITH pcst_result AS (
    SELECT result_nodes, result_edges 
    FROM pcst_fast(
        ARRAY[[0,1], [0,2], [1,3]],
        ARRAY[150.0, 40.0, 60.0, 120.0]::float8[],
        ARRAY[10.0, 15.0, 20.0]::float8[],
        -1, 1, 'simple', 0
    )
)
-- Then visualize
SELECT pcst_visualize(
    ARRAY[[0,1], [0,2], [1,3]], 
    ARRAY[150.0, 40.0, 60.0, 120.0]::float8[],
    result_nodes, 
    result_edges
) FROM pcst_result;