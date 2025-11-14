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
    edges_len integer;
    nodes_len integer;
    edges_result_len integer;
BEGIN
    -- Get array lengths with NULL handling
    edges_len := COALESCE(array_length(edges, 1), 0);
    nodes_len := COALESCE(array_length(result_nodes, 1), 0);
    edges_result_len := COALESCE(array_length(result_edges, 1), 0);

    -- Find maximum node ID to determine layout
    IF edges_len > 0 THEN
        FOR i IN 1..edges_len LOOP
            max_node := GREATEST(max_node, edges[i][1], edges[i][2]);
        END LOOP;
    END IF;

    -- Build output string with inputs first
    output := E'\nPCST Algorithm Input & Results:\n';
    output := output || '======================================' || E'\n';

    -- Show input edges with costs
    output := output || E'\nInput Edges:\n';
    IF edges_len > 0 THEN
        FOR i IN 1..edges_len LOOP
            output := output || 'Edge ' || (i-1) || ': [' || edges[i][1] || ',' || edges[i][2] || '] cost=' || costs[i]::text || E'\n';
        END LOOP;
    END IF;

    -- Show input prizes
    output := output || E'\nInput Node Prizes:\n';
    IF max_node >= 0 THEN
        DECLARE
            prizes_len integer := COALESCE(array_length(prizes, 1), 0);
        BEGIN
            FOR i IN 0..max_node LOOP
                IF i + 1 <= prizes_len THEN
                    output := output || 'Node ' || i || ': prize=' || prizes[i+1]::text || E'\n';
                END IF;
            END LOOP;
        END;
    END IF;

    -- Show results
    output := output || E'\nAlgorithm Results:\n';
    output := output || '==================' || E'\n';
    output := output || 'Selected nodes: ' || COALESCE(array_to_string(result_nodes, ', '), 'none') || E'\n';
    output := output || 'Selected edges: ' || COALESCE(array_to_string(result_edges, ', '), 'none') || E'\n';

    -- Calculate totals
    IF nodes_len > 0 THEN
        FOR i IN 1..nodes_len LOOP
            IF result_nodes[i] + 1 <= COALESCE(array_length(prizes, 1), 0) THEN
                total_selected_prizes := total_selected_prizes + prizes[result_nodes[i] + 1];
            END IF;
        END LOOP;
    END IF;

    IF edges_result_len > 0 THEN
        FOR i IN 1..edges_result_len LOOP
            selected_edge_idx := result_edges[i];
            IF selected_edge_idx + 1 <= COALESCE(array_length(costs, 1), 0) THEN
                total_selected_costs := total_selected_costs + costs[selected_edge_idx + 1];
            END IF;
        END LOOP;
    END IF;

    net_benefit := total_selected_prizes - total_selected_costs;

    -- Add detailed edge analysis with costs
    output := output || E'\nEdge Analysis:\n';
    IF edges_len > 0 THEN
        FOR i IN 1..edges_len LOOP
            edge_from := edges[i][1];
            edge_to := edges[i][2];
            output := output || 'Edge ' || (i-1) || ': [' || edge_from || ',' || edge_to || '] cost=' || costs[i]::text;

            -- Check if this edge is selected
            is_selected := FALSE;
            IF edges_result_len > 0 THEN
                FOR j IN 1..edges_result_len LOOP
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
                    IF nodes_len > 0 THEN
                        FOR j IN 1..nodes_len LOOP
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
    END IF;

    -- Summary statistics with cost analysis
    output := output || E'\nSummary:\n';
    output := output || 'Total selected node prizes: ' || total_selected_prizes::text || E'\n';
    output := output || 'Total selected edge costs: ' || total_selected_costs::text || E'\n';
    output := output || 'Net benefit (prizes - costs): ' || net_benefit::text || E'\n';
    output := output || 'Number of selected nodes: ' || nodes_len::text || E'\n';
    output := output || 'Number of selected edges: ' || edges_result_len::text || E'\n';

    -- Build correct graph representation based on actual selected edges
    output := output || E'\nActual Graph Structure:\n';
    output := output || '(Based on selected edges, not sequential layout)' || E'\n';

    IF edges_result_len > 0 THEN
        output := output || 'Selected edges connect nodes as follows:' || E'\n';
        FOR i IN 1..edges_result_len LOOP
            selected_edge_idx := result_edges[i];
            IF selected_edge_idx + 1 <= edges_len THEN
                edge_from := edges[selected_edge_idx + 1][1];
                edge_to := edges[selected_edge_idx + 1][2];
                output := output || 'Edge ' || selected_edge_idx || ': ' || edge_from || ' ←→ ' || edge_to ||
                         ' (cost=' || costs[selected_edge_idx + 1]::text || ')' || E'\n';
            END IF;
        END LOOP;

        -- Build actual connectivity representation
        output := output || E'\nActual connectivity pattern:' || E'\n';

        -- Show each selected edge as a connection
        FOR i IN 1..edges_result_len LOOP
            selected_edge_idx := result_edges[i];
            IF selected_edge_idx + 1 <= edges_len THEN
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

-- pg_routing-style function that takes SQL queries for edges and nodes
CREATE OR REPLACE FUNCTION pgr_pcst_fast(
    edges_sql text,             -- SQL query returning: id, source, target, cost
    nodes_sql text,              -- SQL query returning: id, prize
    root_id integer DEFAULT -1,  -- Root node ID (or -1 for auto-select)
    num_clusters integer DEFAULT 1,  -- Number of clusters
    pruning text DEFAULT 'simple',   -- Pruning method: 'none', 'simple', 'gw', 'strong'
    verbosity integer DEFAULT 0      -- Verbosity level
)
RETURNS TABLE(
    seq integer,                -- sequence number
    edge bigint,                -- edge ID
    source bigint,              -- source node ID
    target bigint,              -- target node ID
    cost float8                -- edge cost
) AS '$libdir/pcst_fast', 'pcst_fast_pgr'
LANGUAGE C STRICT;

-- Add function documentation
COMMENT ON FUNCTION pgr_pcst_fast(text, text, integer, integer, text, integer) IS
'Prize Collecting Steiner Tree Fast algorithm with pg_routing-style interface.
Takes SQL queries for edges (id, source, target, cost) and nodes (id, prize).
Automatically maps between original IDs and internal indices.

Note: Nodes that appear in edges but not in the nodes query will have prize 0.0.
These nodes can still be selected as "Steiner nodes" if they help connect nodes
with positive prizes, but they do not contribute to the objective function.';

-- Visualization function for pg_routing-style PCST
CREATE OR REPLACE FUNCTION pgr_pcst_fast_with_viz(
    edges_sql text,             -- SQL query returning: id, source, target, cost
    nodes_sql text,              -- SQL query returning: id, prize
    root_id integer DEFAULT -1,  -- Root node ID (or -1 for auto-select)
    num_clusters integer DEFAULT 1,  -- Number of clusters
    pruning text DEFAULT 'simple',   -- Pruning method: 'none', 'simple', 'gw', 'strong'
    verbosity integer DEFAULT 0      -- Verbosity level
)
RETURNS TEXT AS $$
DECLARE
    result_record RECORD;
    viz_output TEXT;
    -- Data storage with original IDs
    edge_rec RECORD;
    node_rec RECORD;
    -- Arrays to store edge data: id, source, target, cost
    edge_ids integer[];
    edge_sources integer[];
    edge_targets integer[];
    edge_costs_array float8[];
    -- Arrays to store node data: id, prize
    node_ids integer[];
    node_prizes_array float8[];
    node_prizes float8[];  -- Maps node_id -> prize
    selected_edges integer[];
    selected_nodes integer[];
    i integer;
    j integer;
    edge_id integer;
    node_id integer;
    edge_from integer;
    edge_to integer;
    is_selected boolean;
    total_selected_prizes float8 := 0;
    total_selected_costs float8 := 0;
    net_benefit float8;
    nodes_len integer;
    edges_len integer;
    max_node_id integer := -1;
BEGIN
    -- First, get the results from pgr_pcst_fast (now returns rows)
    -- Collect selected edges and nodes from the result rows
    selected_edges := ARRAY[]::integer[];
    selected_nodes := ARRAY[]::integer[];

    FOR result_record IN
        SELECT seq, edge, source, target, cost
        FROM pgr_pcst_fast(edges_sql, nodes_sql, root_id, num_clusters, pruning, verbosity)
        ORDER BY seq
    LOOP
        selected_edges := selected_edges || ARRAY[result_record.edge::integer];
        -- Collect unique nodes from source and target
        IF NOT (result_record.source = ANY(selected_nodes)) THEN
            selected_nodes := selected_nodes || ARRAY[result_record.source::integer];
        END IF;
        IF NOT (result_record.target = ANY(selected_nodes)) THEN
            selected_nodes := selected_nodes || ARRAY[result_record.target::integer];
        END IF;
    END LOOP;

    -- Initialize arrays to store edge and node data
    edge_ids := ARRAY[]::integer[];
    edge_sources := ARRAY[]::integer[];
    edge_targets := ARRAY[]::integer[];
    edge_costs_array := ARRAY[]::float8[];
    node_ids := ARRAY[]::integer[];
    node_prizes_array := ARRAY[]::float8[];

    -- Collect all edges with original IDs
    FOR edge_rec IN EXECUTE edges_sql LOOP
        edge_ids := edge_ids || ARRAY[edge_rec.id];
        edge_sources := edge_sources || ARRAY[edge_rec.source];
        edge_targets := edge_targets || ARRAY[edge_rec.target];
        edge_costs_array := edge_costs_array || ARRAY[edge_rec.cost];
        max_node_id := GREATEST(max_node_id, edge_rec.source, edge_rec.target);
    END LOOP;

    -- Collect all nodes with original IDs
    FOR node_rec IN EXECUTE nodes_sql LOOP
        node_ids := node_ids || ARRAY[node_rec.id];
        node_prizes_array := node_prizes_array || ARRAY[node_rec.prize];
    END LOOP;

    -- Initialize mapping arrays
    IF max_node_id >= 0 THEN
        node_prizes := array_fill(0.0::float8, ARRAY[max_node_id + 1]);
    ELSE
        node_prizes := ARRAY[]::float8[];
    END IF;

    -- Build node prizes map
    FOR i IN 1..array_length(node_ids, 1) LOOP
        node_id := node_ids[i];
        IF node_id >= 0 AND node_id <= max_node_id THEN
            node_prizes[node_id + 1] := node_prizes_array[i];
        END IF;
    END LOOP;

    -- Get lengths (already collected above)
    nodes_len := COALESCE(array_length(selected_nodes, 1), 0);
    edges_len := COALESCE(array_length(selected_edges, 1), 0);

    -- Calculate totals
    FOR i IN 1..nodes_len LOOP
        node_id := selected_nodes[i];
        IF node_id >= 0 AND node_id <= max_node_id THEN
            total_selected_prizes := total_selected_prizes + node_prizes[node_id + 1];
        END IF;
    END LOOP;

    FOR i IN 1..array_length(edge_ids, 1) LOOP
        edge_id := edge_ids[i];
        -- Check if this edge is selected
        is_selected := FALSE;
        FOR j IN 1..edges_len LOOP
            IF selected_edges[j] = edge_id THEN
                is_selected := TRUE;
                total_selected_costs := total_selected_costs + edge_costs_array[i];
                EXIT;
            END IF;
        END LOOP;
    END LOOP;

    net_benefit := total_selected_prizes - total_selected_costs;

    -- Build visualization output
    viz_output := E'\nPCST Algorithm Input & Results:\n';
    viz_output := viz_output || '======================================' || E'\n';

    -- Show input edges with costs (using original IDs)
    viz_output := viz_output || E'\nInput Edges:\n';
    FOR i IN 1..array_length(edge_ids, 1) LOOP
        viz_output := viz_output || 'Edge ' || edge_ids[i] || ': [' ||
                     edge_sources[i] || ',' || edge_targets[i] ||
                     '] cost=' || edge_costs_array[i]::text || E'\n';
    END LOOP;

    -- Show input node prizes (using original IDs)
    viz_output := viz_output || E'\nInput Node Prizes:\n';
    FOR i IN 1..array_length(node_ids, 1) LOOP
        viz_output := viz_output || 'Node ' || node_ids[i] || ': prize=' ||
                     node_prizes_array[i]::text || E'\n';
    END LOOP;

    -- Show results (using original IDs)
    viz_output := viz_output || E'\nAlgorithm Results:\n';
    viz_output := viz_output || '==================' || E'\n';
    viz_output := viz_output || 'Selected nodes: ' ||
                 COALESCE(array_to_string(selected_nodes, ', '), 'none') || E'\n';
    viz_output := viz_output || 'Selected edges: ' ||
                 COALESCE(array_to_string(selected_edges, ', '), 'none') || E'\n';

    -- Edge analysis (using original IDs)
    viz_output := viz_output || E'\nEdge Analysis:\n';
    FOR i IN 1..array_length(edge_ids, 1) LOOP
        edge_id := edge_ids[i];
        edge_from := edge_sources[i];
        edge_to := edge_targets[i];
        viz_output := viz_output || 'Edge ' || edge_id || ': [' || edge_from || ',' ||
                     edge_to || '] cost=' || edge_costs_array[i]::text;

        -- Check if this edge is selected
        is_selected := FALSE;
        FOR j IN 1..edges_len LOOP
            IF selected_edges[j] = edge_id THEN
                is_selected := TRUE;
                viz_output := viz_output || ' [SELECTED]';
                EXIT;
            END IF;
        END LOOP;

        IF NOT is_selected THEN
            viz_output := viz_output || ' [unselected]';
        END IF;

        -- Check connectivity for selected edges
        IF is_selected THEN
            DECLARE
                from_selected boolean := FALSE;
                to_selected boolean := FALSE;
            BEGIN
                FOR j IN 1..nodes_len LOOP
                    IF selected_nodes[j] = edge_from THEN from_selected := TRUE; END IF;
                    IF selected_nodes[j] = edge_to THEN to_selected := TRUE; END IF;
                END LOOP;

                IF NOT (from_selected AND to_selected) THEN
                    viz_output := viz_output || ' [WARNING: Edge endpoints not both selected!]';
                END IF;
            END;
        END IF;

        viz_output := viz_output || E'\n';
    END LOOP;

    -- Summary
    viz_output := viz_output || E'\nSummary:\n';
    viz_output := viz_output || 'Total selected node prizes: ' || total_selected_prizes::text || E'\n';
    viz_output := viz_output || 'Total selected edge costs: ' || total_selected_costs::text || E'\n';
    viz_output := viz_output || 'Net benefit (prizes - costs): ' || net_benefit::text || E'\n';
    viz_output := viz_output || 'Number of selected nodes: ' || nodes_len::text || E'\n';
    viz_output := viz_output || 'Number of selected edges: ' || edges_len::text || E'\n';

    -- Graph structure (using original IDs)
    viz_output := viz_output || E'\nActual Graph Structure:\n';
    viz_output := viz_output || '(Based on selected edges, not sequential layout)' || E'\n';

    IF edges_len > 0 THEN
        viz_output := viz_output || 'Selected edges connect nodes as follows:' || E'\n';
        FOR i IN 1..edges_len LOOP
            edge_id := selected_edges[i];
            -- Find this edge in edge arrays
            FOR j IN 1..array_length(edge_ids, 1) LOOP
                IF edge_ids[j] = edge_id THEN
                    edge_from := edge_sources[j];
                    edge_to := edge_targets[j];
                    viz_output := viz_output || 'Edge ' || edge_id || ': ' || edge_from ||
                                 ' ←→ ' || edge_to || ' (cost=' || edge_costs_array[j]::text || ')' || E'\n';
                    EXIT;
                END IF;
            END LOOP;
        END LOOP;

        viz_output := viz_output || E'\nActual connectivity pattern:' || E'\n';
        FOR i IN 1..edges_len LOOP
            edge_id := selected_edges[i];
            FOR j IN 1..array_length(edge_ids, 1) LOOP
                IF edge_ids[j] = edge_id THEN
                    edge_from := edge_sources[j];
                    edge_to := edge_targets[j];
                    viz_output := viz_output || '[' || edge_from || ']———[' || edge_to ||
                                 '] (via edge ' || edge_id || ')' || E'\n';
                    EXIT;
                END IF;
            END LOOP;
        END LOOP;
        viz_output := viz_output || E'\nNote: This shows individual connections. For complex graphs, nodes may have multiple connections.' || E'\n';
    ELSE
        viz_output := viz_output || 'No edges selected - nodes are isolated' || E'\n';
    END IF;

    -- Legend
    viz_output := viz_output || E'\nLegend:\n';
    viz_output := viz_output || '[n] = selected node n with its prize value' || E'\n';
    viz_output := viz_output || '←→ = bidirectional edge connection' || E'\n';
    viz_output := viz_output || 'cost=X = edge traversal cost' || E'\n';

    RETURN viz_output;
END;
$$ LANGUAGE plpgsql;

-- Add comment
COMMENT ON FUNCTION pgr_pcst_fast_with_viz(text, text, integer, integer, text, integer) IS
'Runs pgr_pcst_fast algorithm and returns ASCII art visualization of the result with edge costs and correct graph layout. Useful for debugging the pg_routing-style interface.';