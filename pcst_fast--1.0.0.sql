-- pcst_fast extension SQL script
-- This file contains the SQL definitions for the PCST Fast extension

-- Drop old function signatures if they exist
DROP FUNCTION IF EXISTS pcst_fast(integer[][], float8[], float8[], integer, integer, text, integer);
DROP FUNCTION IF EXISTS pcst_visualize(integer[][], float8[], integer[], integer[]);

-- Create the main PCST Fast function (C implementation) with array-based interface
CREATE OR REPLACE FUNCTION pcst_fast(
    edges integer[][],         -- array of [from, to] pairs
    prizes float8[],           -- array of floats
    costs float8[],            -- array of floats
    root integer,              -- int (or -1 for no root)
    num_clusters integer,      -- int
    pruning text,              -- string: 'none', 'simple', 'gw', 'strong'
    verbosity integer          -- int
)
RETURNS TABLE(
    result_nodes integer[],    -- array of node indices
    result_edges integer[]     -- array of edge indices
) AS '$libdir/pcst_fast', 'pcst_fast_pg'
LANGUAGE C STRICT;

-- Add function documentation
COMMENT ON FUNCTION pcst_fast(integer[][], float8[], float8[], integer, integer, text, integer) IS 
'Prize Collecting Steiner Tree Fast algorithm - finds optimal subset of nodes and edges maximizing (prizes - costs) while maintaining connectivity';

-- Enhanced visualization function with costs and correct graph layout
CREATE OR REPLACE FUNCTION pcst_visualize_with_costs(
    edges integer[][],         -- Original edges array
    prizes float8[],           -- Original prizes array  
    costs float8[],            -- Original costs array
    result_nodes integer[],    -- Selected nodes from pcst_fast
    result_edges integer[]     -- Selected edges from pcst_fast
)
RETURNS TEXT AS $$
DECLARE
    output TEXT := '';
    max_node integer := 0;
    i integer;
    j integer;
    edge_from integer;
    edge_to integer;
    selected_edge_idx integer;
    is_selected boolean;
    total_selected_prizes float8 := 0;
    total_selected_costs float8 := 0;
    net_benefit float8;
    -- Graph structure variables
    adjacency_list TEXT[];
    visited_nodes boolean[];
    current_node integer;
    connected_component TEXT;
BEGIN
    -- Find maximum node ID to determine layout
    FOR i IN 1..array_length(edges, 1) LOOP
        max_node := GREATEST(max_node, edges[i][1], edges[i][2]);
    END LOOP;
    
    -- Build output string with inputs first
    output := E'\nPCST Algorithm Input & Results:\n';
    output := output || '======================================' || E'\n';
    
    -- Show input edges with costs
    output := output || E'\nInput Edges:\n';
    FOR i IN 1..array_length(edges, 1) LOOP
        output := output || 'Edge ' || (i-1) || ': [' || edges[i][1] || ',' || edges[i][2] || '] cost=' || costs[i]::text || E'\n';
    END LOOP;
    
    -- Show input prizes
    output := output || E'\nInput Node Prizes:\n';
    FOR i IN 0..max_node LOOP
        IF i + 1 <= array_length(prizes, 1) THEN
            output := output || 'Node ' || i || ': prize=' || prizes[i+1]::text || E'\n';
        END IF;
    END LOOP;
    
    -- Show results
    output := output || E'\nAlgorithm Results:\n';
    output := output || '==================' || E'\n';
    output := output || 'Selected nodes: ' || COALESCE(array_to_string(result_nodes, ', '), 'none') || E'\n';
    output := output || 'Selected edges: ' || COALESCE(array_to_string(result_edges, ', '), 'none') || E'\n';
    
    -- Calculate totals
    IF result_nodes IS NOT NULL THEN
        FOR i IN 1..array_length(result_nodes, 1) LOOP
            IF result_nodes[i] + 1 <= array_length(prizes, 1) THEN
                total_selected_prizes := total_selected_prizes + prizes[result_nodes[i] + 1];
            END IF;
        END LOOP;
    END IF;
    
    IF result_edges IS NOT NULL THEN
        FOR i IN 1..array_length(result_edges, 1) LOOP
            selected_edge_idx := result_edges[i];
            IF selected_edge_idx + 1 <= array_length(costs, 1) THEN
                total_selected_costs := total_selected_costs + costs[selected_edge_idx + 1];
            END IF;
        END LOOP;
    END IF;
    
    net_benefit := total_selected_prizes - total_selected_costs;
    
    -- Add detailed edge analysis with costs
    output := output || E'\nEdge Analysis:\n';
    FOR i IN 1..array_length(edges, 1) LOOP
        edge_from := edges[i][1];
        edge_to := edges[i][2];
        output := output || 'Edge ' || (i-1) || ': [' || edge_from || ',' || edge_to || '] cost=' || costs[i]::text;
        
        -- Check if this edge is selected
        is_selected := FALSE;
        IF result_edges IS NOT NULL THEN
            FOR j IN 1..array_length(result_edges, 1) LOOP
                IF result_edges[j] = (i-1) THEN  -- Adjust for 0-based indexing
                    output := output || ' [SELECTED]';
                    is_selected := TRUE;
                    EXIT;
                END IF;
            END LOOP;
        END IF;
        
        IF NOT is_selected THEN
            output := output || ' [unselected]';
        END IF;
        
        -- Add connectivity check for selected edges
        IF is_selected THEN
            -- Check if both endpoints are in selected nodes
            DECLARE
                from_selected boolean := FALSE;
                to_selected boolean := FALSE;
            BEGIN
                IF result_nodes IS NOT NULL THEN
                    FOR j IN 1..array_length(result_nodes, 1) LOOP
                        IF result_nodes[j] = edge_from THEN from_selected := TRUE; END IF;
                        IF result_nodes[j] = edge_to THEN to_selected := TRUE; END IF;
                    END LOOP;
                END IF;
                
                IF NOT (from_selected AND to_selected) THEN
                    output := output || ' [WARNING: Edge endpoints not both selected!]';
                END IF;
            END;
        END IF;
        
        output := output || E'\n';
    END LOOP;
    
    -- Summary statistics with cost analysis
    output := output || E'\nSummary:\n';
    output := output || 'Total selected node prizes: ' || total_selected_prizes::text || E'\n';
    output := output || 'Total selected edge costs: ' || total_selected_costs::text || E'\n';
    output := output || 'Net benefit (prizes - costs): ' || net_benefit::text || E'\n';
    output := output || 'Number of selected nodes: ' || COALESCE(array_length(result_nodes, 1)::text, '0') || E'\n';
    output := output || 'Number of selected edges: ' || COALESCE(array_length(result_edges, 1)::text, '0') || E'\n';
    
    -- Build correct graph representation based on actual selected edges
    output := output || E'\nActual Graph Structure:\n';
    output := output || '(Based on selected edges, not sequential layout)' || E'\n';
    
    IF result_edges IS NOT NULL AND array_length(result_edges, 1) > 0 THEN
        output := output || 'Selected edges connect nodes as follows:' || E'\n';
        FOR i IN 1..array_length(result_edges, 1) LOOP
            selected_edge_idx := result_edges[i];
            IF selected_edge_idx + 1 <= array_length(edges, 1) THEN
                edge_from := edges[selected_edge_idx + 1][1];
                edge_to := edges[selected_edge_idx + 1][2];
                output := output || 'Edge ' || selected_edge_idx || ': ' || edge_from || ' ←→ ' || edge_to || 
                         ' (cost=' || costs[selected_edge_idx + 1]::text || ')' || E'\n';
            END IF;
        END LOOP;
        
        -- Build actual connectivity representation
        output := output || E'\nActual connectivity pattern:' || E'\n';
        
        -- Show each selected edge as a connection
        FOR i IN 1..array_length(result_edges, 1) LOOP
            selected_edge_idx := result_edges[i];
            IF selected_edge_idx + 1 <= array_length(edges, 1) THEN
                edge_from := edges[selected_edge_idx + 1][1];
                edge_to := edges[selected_edge_idx + 1][2];
                output := output || '[' || edge_from || ']———[' || edge_to || '] (via edge ' || selected_edge_idx || ')' || E'\n';
            END IF;
        END LOOP;
        
        output := output || E'\nNote: This shows individual connections. For complex graphs, nodes may have multiple connections.' || E'\n';
    ELSE
        output := output || 'No edges selected - nodes are isolated' || E'\n';
    END IF;
    
    -- Add legend
    output := output || E'\nLegend:\n';
    output := output || '[n] = selected node n with its prize value' || E'\n';
    output := output || '←→ = bidirectional edge connection' || E'\n';
    output := output || 'cost=X = edge traversal cost' || E'\n';
    
    RETURN output;
END;
$$ LANGUAGE plpgsql;

-- Convenience function that runs PCST and visualizes the result
CREATE OR REPLACE FUNCTION pcst_fast_with_viz(
    edges integer[][],
    prizes float8[],
    costs float8[],
    root integer DEFAULT -1,
    num_clusters integer DEFAULT 1,
    pruning text DEFAULT 'simple',
    verbosity integer DEFAULT 0
)
RETURNS TEXT AS $$
DECLARE
    result_record RECORD;
    viz_output TEXT;
BEGIN
    -- Run the PCST algorithm
    SELECT result_nodes, result_edges INTO result_record
    FROM pcst_fast(edges, prizes, costs, root, num_clusters, pruning, verbosity);
    
    -- Generate visualization with costs
    SELECT pcst_visualize_with_costs(edges, prizes, costs, result_record.result_nodes, result_record.result_edges)
    INTO viz_output;
    
    RETURN viz_output;
END;
$$ LANGUAGE plpgsql;

-- Add comment
COMMENT ON FUNCTION pcst_fast_with_viz(integer[][], float8[], float8[], integer, integer, text, integer) IS
'Runs PCST algorithm and returns ASCII art visualization of the result with edge costs and correct graph layout';