#include "postgres.h"
#include "fmgr.h"
#include "funcapi.h"
#include "access/htup_details.h"
#include "catalog/pg_type.h"
#include "utils/builtins.h"
#include "utils/array.h"
#include "utils/lsyscache.h"
#include "executor/spi.h"
#include "lib/stringinfo.h"
#include "utils/hsearch.h"
#include "pcst_fast_c_wrapper.h"

PG_MODULE_MAGIC;

/* Function declarations */
PG_FUNCTION_INFO_V1(pcst_fast_pg);
PG_FUNCTION_INFO_V1(pcst_fast_pgr);

/* Helper structures for storing intermediate data */
typedef struct {
    int *edge_sources;
    int *edge_targets;
    double *edge_costs;
    int num_edges;
    double *node_prizes;
    int num_nodes;
    int max_node_id;
} pcst_input_data;

/* Structure to store ID mapping and result data for pgr-style function */
typedef struct {
    int *node_id_to_index;      // Maps original node ID -> internal index
    int *index_to_node_id;      // Maps internal index -> original node ID
    int *edge_id_to_index;      // Maps original edge ID -> internal index
    int *index_to_edge_id;      // Maps internal index -> original edge ID
    int *edge_sources;           // Original source node IDs for edges
    int *edge_targets;           // Original target node IDs for edges
    double *edge_costs;         // Edge costs
    int max_node_id;            // Maximum node ID seen
    int num_nodes;              // Number of unique nodes
    int num_edges;              // Number of edges
    pcst_result_t *result;      // PCST result with internal indices
    int current_edge;           // Current edge index for row-by-row return
} pgr_result_data;

/* Main PCST function */
Datum pcst_fast_pg(PG_FUNCTION_ARGS) {
    ArrayType *edges_array = PG_GETARG_ARRAYTYPE_P(0);
    ArrayType *prizes_array = PG_GETARG_ARRAYTYPE_P(1);
    ArrayType *costs_array = PG_GETARG_ARRAYTYPE_P(2);
    int root = PG_GETARG_INT32(3);
    int num_clusters = PG_GETARG_INT32(4);
    text *pruning_text = PG_GETARG_TEXT_P(5);
    int verbosity = PG_GETARG_INT32(6);

    FuncCallContext *funcctx;
    TupleDesc tupdesc;

    if (SRF_IS_FIRSTCALL()) {
        MemoryContext oldcontext;
        funcctx = SRF_FIRSTCALL_INIT();
        oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);

        // Build tuple descriptor for return type
        if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
            ereport(ERROR,
                    (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                     errmsg("function returning record called in context "
                            "that cannot accept a set")));

        funcctx->tuple_desc = BlessTupleDesc(tupdesc);

        // Extract edges array (should be integer[][])
        int ndims = ARR_NDIM(edges_array);
        int *dims = ARR_DIMS(edges_array);

        if (ndims != 2 || dims[1] != 2)
            ereport(ERROR, (errcode(ERRCODE_ARRAY_SUBSCRIPT_ERROR),
                           errmsg("edges array must be 2D with second dimension = 2")));

        int num_edges = dims[0];
        int32 *edges_data = (int32 *) ARR_DATA_PTR(edges_array);

        // Extract arrays
        float8 *prizes_data = (float8 *) ARR_DATA_PTR(prizes_array);
        float8 *costs_data = (float8 *) ARR_DATA_PTR(costs_array);

        int num_nodes = ARR_DIMS(prizes_array)[0];

        // Convert edges to separate source/target arrays
        int *edge_sources = (int *) palloc(num_edges * sizeof(int));
        int *edge_targets = (int *) palloc(num_edges * sizeof(int));

        for (int i = 0; i < num_edges; i++) {
            edge_sources[i] = edges_data[i * 2];
            edge_targets[i] = edges_data[i * 2 + 1];
        }

        // Convert pruning string to enum
        char *pruning_str = text_to_cstring(pruning_text);
        int pruning_method;
        if (strcmp(pruning_str, "none") == 0)
            pruning_method = 0;
        else if (strcmp(pruning_str, "simple") == 0)
            pruning_method = 1;
        else if (strcmp(pruning_str, "gw") == 0)
            pruning_method = 2;
        else if (strcmp(pruning_str, "strong") == 0)
            pruning_method = 3;
        else
            pruning_method = 2; // default to GW

        // Call the C function
        pcst_result_t *result = pcst_solve(
            edge_sources, edge_targets, costs_data, num_edges,
            prizes_data, num_nodes,
            root, num_clusters, pruning_method, verbosity
        );

        if (!result || !result->success) {
            const char *error_msg = result ? result->error_message : "Unknown error";
            if (result) pcst_free_result(result);
            ereport(ERROR, (errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
                           errmsg("PCST algorithm failed: %s", error_msg)));
        }

        // Store result for return
        funcctx->user_fctx = result;
        funcctx->max_calls = 1; // We return one row with arrays

        MemoryContextSwitchTo(oldcontext);
    }

    funcctx = SRF_PERCALL_SETUP();

    if (funcctx->call_cntr < funcctx->max_calls) {
        pcst_result_t *result = (pcst_result_t *) funcctx->user_fctx;
        HeapTuple tuple;
        Datum values[2];
        bool nulls[2] = {false, false};

        // Create result arrays
        Datum *nodes_datums = (Datum *) palloc(result->num_nodes * sizeof(Datum));
        Datum *edges_datums = (Datum *) palloc(result->num_edges * sizeof(Datum));

        for (int i = 0; i < result->num_nodes; i++)
            nodes_datums[i] = Int32GetDatum(result->result_nodes[i]);

        for (int i = 0; i < result->num_edges; i++)
            edges_datums[i] = Int32GetDatum(result->result_edges[i]);

        ArrayType *nodes_array = construct_array(nodes_datums, result->num_nodes,
                                                INT4OID, 4, true, 'i');
        ArrayType *edges_array = construct_array(edges_datums, result->num_edges,
                                                INT4OID, 4, true, 'i');

        values[0] = PointerGetDatum(nodes_array);
        values[1] = PointerGetDatum(edges_array);

        tuple = heap_form_tuple(funcctx->tuple_desc, values, nulls);

        SRF_RETURN_NEXT(funcctx, HeapTupleGetDatum(tuple));
    } else {
        // Clean up
        pcst_result_t *result = (pcst_result_t *) funcctx->user_fctx;
        if (result) pcst_free_result(result);

        SRF_RETURN_DONE(funcctx);
    }
}

/* Hash table entry structure for node ID mapping */
typedef struct {
    int node_id;    // Key
    int index;      // Value
} node_map_entry;

/* Hash function for integer keys */
static uint32 node_id_hash(const void *key, Size keysize) {
    const int *ikey = (const int *) key;
    // Simple hash: use the integer value directly
    // For better distribution with large numbers, we could use a better hash
    return (uint32) *ikey;
}

/* Match function for integer keys */
static int node_id_match(const void *key1, const void *key2, Size keysize) {
    const int *k1 = (const int *) key1;
    const int *k2 = (const int *) key2;
    return (*k1 == *k2) ? 0 : 1;
}

/* Helper function to find or add node ID to mapping using hash table */
static int get_node_index(HTAB *node_map, int *next_index, int node_id, int **index_to_node_id, int verbosity) {
    bool found;
    node_map_entry *entry;

    // Search for existing entry
    entry = (node_map_entry *) hash_search(node_map, &node_id, HASH_ENTER, &found);
    if (!found) {
        // New entry - set the index
        int new_index = (*next_index)++;
        entry->node_id = node_id;
        entry->index = new_index;

        // Reallocate index_to_node_id array if needed
        *index_to_node_id = (int *) repalloc(*index_to_node_id, (*next_index) * sizeof(int));
        (*index_to_node_id)[new_index] = node_id;

        if (verbosity > 1) {
            elog(INFO, "get_node_index: NEW node_id=%d -> index=%d", node_id, new_index);
        }
    } else {
        if (verbosity > 1) {
            elog(INFO, "get_node_index: FOUND node_id=%d -> index=%d", node_id, entry->index);
        }
    }

    return entry->index;
}

/* pg_routing-style PCST function that takes SQL queries */
Datum pcst_fast_pgr(PG_FUNCTION_ARGS) {
    text *edges_sql = PG_GETARG_TEXT_P(0);
    text *nodes_sql = PG_GETARG_TEXT_P(1);
    int root_id = PG_GETARG_INT32(2);  // Original node ID, or -1
    int num_clusters = PG_GETARG_INT32(3);
    text *pruning_text = PG_GETARG_TEXT_P(4);
    int verbosity = PG_GETARG_INT32(5);

    FuncCallContext *funcctx;
    TupleDesc tupdesc;
    HASHCTL hash_ctl;
    HTAB *node_map = NULL;
    MemoryContext oldcontext;

    if (SRF_IS_FIRSTCALL()) {
        int ret;
        int next_node_index = 0;
        int num_edges = 0;
        int num_nodes = 0;
        int max_edges = 1024;
        int *edge_ids = NULL;
        int *edge_sources = NULL;
        int *edge_targets = NULL;
        double *edge_costs = NULL;
        int *index_to_node_id = NULL;
        double *node_prizes = NULL;
        int root_index = -1;
        char *edges_sql_str;
        char *nodes_sql_str;
        char *pruning_str;
        int pruning_method;
        pgr_result_data *pgr_data;

        funcctx = SRF_FIRSTCALL_INIT();
        oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);

        // Build tuple descriptor
        if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
            ereport(ERROR,
                    (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                     errmsg("function returning record called in context "
                            "that cannot accept a set")));

        funcctx->tuple_desc = BlessTupleDesc(tupdesc);

        // Initialize SPI
        if ((ret = SPI_connect()) != SPI_OK_CONNECT)
            ereport(ERROR,
                    (errcode(ERRCODE_INTERNAL_ERROR),
                     errmsg("SPI_connect failed: %d", ret)));

        // Initialize hash table for node ID mapping
        // Use a structure for entries so we can store both key and value
        memset(&hash_ctl, 0, sizeof(hash_ctl));
        hash_ctl.keysize = sizeof(int);           // Key is node_id (int)
        hash_ctl.entrysize = sizeof(node_map_entry);  // Entry contains node_id and index
        hash_ctl.hash = node_id_hash;
        hash_ctl.match = node_id_match;
        hash_ctl.hcxt = CurrentMemoryContext;
        node_map = hash_create("node_id_map", 1024, &hash_ctl,
                               HASH_ELEM | HASH_FUNCTION | HASH_COMPARE | HASH_CONTEXT);

        // Allocate arrays
        edge_ids = (int *) palloc(max_edges * sizeof(int));
        edge_sources = (int *) palloc(max_edges * sizeof(int));
        edge_targets = (int *) palloc(max_edges * sizeof(int));
        edge_costs = (double *) palloc(max_edges * sizeof(double));
        // Allocate initial array - will be reallocated as needed
        // Initialize to -1 to help detect uninitialized values
        index_to_node_id = (int *) palloc(1024 * sizeof(int));
        memset(index_to_node_id, -1, 1024 * sizeof(int));

        // Execute edges query
        edges_sql_str = text_to_cstring(edges_sql);
        ret = SPI_execute(edges_sql_str, true, 0);
        if (ret != SPI_OK_SELECT)
            ereport(ERROR,
                    (errcode(ERRCODE_INTERNAL_ERROR),
                     errmsg("edges query failed: %s", SPI_result_code_string(ret))));

        if (SPI_tuptable == NULL || SPI_processed == 0)
            ereport(ERROR,
                    (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                     errmsg("edges query returned no rows")));

        // Check tuple descriptor for edges (expect: id, source, target, cost)
        TupleDesc edges_tupdesc = SPI_tuptable->tupdesc;
        if (edges_tupdesc->natts < 4)
            ereport(ERROR,
                    (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                     errmsg("edges query must return at least 4 columns: id, source, target, cost")));

        // Process edges
        num_edges = SPI_processed;
        if (num_edges > max_edges) {
            max_edges = num_edges;
            edge_ids = (int *) repalloc(edge_ids, max_edges * sizeof(int));
            edge_sources = (int *) repalloc(edge_sources, max_edges * sizeof(int));
            edge_targets = (int *) repalloc(edge_targets, max_edges * sizeof(int));
            edge_costs = (double *) repalloc(edge_costs, max_edges * sizeof(double));
        }

        for (unsigned long i = 0; i < SPI_processed; i++) {
            HeapTuple tuple = SPI_tuptable->vals[i];
            bool isnull;
            Datum edge_id_datum = SPI_getbinval(tuple, edges_tupdesc, 1, &isnull);
            Datum source_datum = SPI_getbinval(tuple, edges_tupdesc, 2, &isnull);
            Datum target_datum = SPI_getbinval(tuple, edges_tupdesc, 3, &isnull);
            Datum cost_datum = SPI_getbinval(tuple, edges_tupdesc, 4, &isnull);

            if (isnull)
                ereport(ERROR,
                        (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                         errmsg("edges query cannot return NULL values")));

            int edge_id = DatumGetInt32(edge_id_datum);
            int source_id = DatumGetInt32(source_datum);
            int target_id = DatumGetInt32(target_datum);
            double cost = DatumGetFloat8(cost_datum);

            edge_ids[i] = edge_id;
            edge_sources[i] = get_node_index(node_map, &next_node_index, source_id, &index_to_node_id, verbosity);
            edge_targets[i] = get_node_index(node_map, &next_node_index, target_id, &index_to_node_id, verbosity);
            edge_costs[i] = cost;
        }

        num_nodes = next_node_index;

        // Allocate node prizes array (zero-initialized)
        // All nodes that appear in edges will have prize 0 by default
        node_prizes = (double *) palloc0(num_nodes * sizeof(double));

        // Execute nodes query
        nodes_sql_str = text_to_cstring(nodes_sql);
        ret = SPI_execute(nodes_sql_str, true, 0);
        if (ret != SPI_OK_SELECT)
            ereport(ERROR,
                    (errcode(ERRCODE_INTERNAL_ERROR),
                     errmsg("nodes query failed: %s", SPI_result_code_string(ret))));

        if (SPI_tuptable != NULL && SPI_processed > 0) {
            TupleDesc nodes_tupdesc = SPI_tuptable->tupdesc;
            if (nodes_tupdesc->natts < 2)
                ereport(ERROR,
                        (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                         errmsg("nodes query must return at least 2 columns: id, prize")));

            // Process nodes and set prizes
            // Note: nodes that appear in edges but not in nodes query will have prize 0
            for (unsigned long i = 0; i < SPI_processed; i++) {
                HeapTuple tuple = SPI_tuptable->vals[i];
                bool isnull;
                Datum node_id_datum = SPI_getbinval(tuple, nodes_tupdesc, 1, &isnull);
                Datum prize_datum = SPI_getbinval(tuple, nodes_tupdesc, 2, &isnull);

                if (isnull)
                    continue;  // Skip NULL values

                int node_id = DatumGetInt32(node_id_datum);
                double prize = DatumGetFloat8(prize_datum);

                // Find node index using hash table
                bool found;
                node_map_entry *entry = (node_map_entry *) hash_search(node_map, &node_id, HASH_FIND, &found);

                if (found && entry != NULL) {
                    int node_index = entry->index;
                    if (node_index >= 0 && node_index < num_nodes) {
                        node_prizes[node_index] = prize;
                    } else {
                        if (verbosity > 1) {
                            elog(WARNING, "pgr_pcst_fast: node_id=%d mapped to invalid index %d (num_nodes=%d)",
                                 node_id, node_index, num_nodes);
                        }
                    }
                } else {
                    // Node in nodes query but not in edges - this is OK, just skip it
                    if (verbosity > 1) {
                        elog(INFO, "pgr_pcst_fast: node_id=%d in nodes query but not in edges, skipping", node_id);
                    }
                }
            }

            // Debug: Log all node prizes after setting them
            if (verbosity > 0) {
                elog(INFO, "pgr_pcst_fast: Total nodes processed: %d", num_nodes);
                for (int i = 0; i < num_nodes && i < 20; i++) {
                    elog(INFO, "pgr_pcst_fast: After processing nodes, node[%d] (id=%d) prize=%.2f",
                         i, (i < num_nodes) ? index_to_node_id[i] : -1, node_prizes[i]);
                }
            }
        } else {
            // No nodes query results - all prizes remain 0
            if (verbosity > 0) {
                elog(WARNING, "pgr_pcst_fast: nodes query returned no results, all node prizes are 0");
            }
        }

        // Map root node ID to index
        if (root_id >= 0) {
            bool found;
            node_map_entry *entry = (node_map_entry *) hash_search(node_map, &root_id, HASH_FIND, &found);
            if (!found || entry == NULL)
                ereport(ERROR,
                        (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                         errmsg("root node ID %d not found in edges", root_id)));
            root_index = entry->index;
        }

        // Convert pruning string to enum
        pruning_str = text_to_cstring(pruning_text);
        if (strcmp(pruning_str, "none") == 0)
            pruning_method = 0;
        else if (strcmp(pruning_str, "simple") == 0)
            pruning_method = 1;
        else if (strcmp(pruning_str, "gw") == 0)
            pruning_method = 2;
        else if (strcmp(pruning_str, "strong") == 0)
            pruning_method = 3;
        else
            pruning_method = 2; // default to GW

        // Debug: Verify node prizes are set correctly
        // (This can be removed after debugging)
        if (verbosity > 0) {
            elog(INFO, "pgr_pcst_fast: num_nodes=%d, num_edges=%d, root_index=%d",
                 num_nodes, num_edges, root_index);
            for (int i = 0; i < num_nodes && i < 10; i++) {
                elog(INFO, "  node[%d] (id=%d) prize=%.2f",
                     i, index_to_node_id[i], node_prizes[i]);
            }
            for (int i = 0; i < num_edges && i < 10; i++) {
                elog(INFO, "  edge[%d] (id=%d): %d->%d cost=%.2f",
                     i, edge_ids[i], edge_sources[i], edge_targets[i], edge_costs[i]);
            }
        }

        // Call the C function
        pcst_result_t *result = pcst_solve(
            edge_sources, edge_targets, edge_costs, num_edges,
            node_prizes, num_nodes,
            root_index, num_clusters, pruning_method, verbosity
        );

        if (!result || !result->success) {
            const char *error_msg = result ? result->error_message : "Unknown error";
            if (result) pcst_free_result(result);
            SPI_finish();
            ereport(ERROR, (errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
                           errmsg("PCST algorithm failed: %s", error_msg)));
        }

        // Store original edge source/target IDs and costs for result rows
        // We need to map internal indices back to original node IDs
        int *original_edge_sources = (int *) palloc(num_edges * sizeof(int));
        int *original_edge_targets = (int *) palloc(num_edges * sizeof(int));
        double *original_edge_costs = (double *) palloc(num_edges * sizeof(double));

        // Re-execute edges query to get original IDs (or we could store them during first pass)
        // Actually, we already have edge_sources and edge_targets as internal indices
        // We need to map them back to original node IDs
        for (int i = 0; i < num_edges; i++) {
            if (edge_sources[i] >= 0 && edge_sources[i] < num_nodes) {
                original_edge_sources[i] = index_to_node_id[edge_sources[i]];
            } else {
                original_edge_sources[i] = -1;
            }
            if (edge_targets[i] >= 0 && edge_targets[i] < num_nodes) {
                original_edge_targets[i] = index_to_node_id[edge_targets[i]];
            } else {
                original_edge_targets[i] = -1;
            }
            original_edge_costs[i] = edge_costs[i];
        }

        // Store result with mappings
        pgr_data = (pgr_result_data *) palloc(sizeof(pgr_result_data));
        pgr_data->result = result;
        pgr_data->num_nodes = num_nodes;
        pgr_data->num_edges = num_edges;
        pgr_data->index_to_node_id = index_to_node_id;
        pgr_data->index_to_edge_id = edge_ids;
        pgr_data->edge_sources = original_edge_sources;
        pgr_data->edge_targets = original_edge_targets;
        pgr_data->edge_costs = original_edge_costs;
        pgr_data->node_id_to_index = NULL;  // Not needed for reverse mapping
        pgr_data->edge_id_to_index = NULL;  // Not needed for reverse mapping
        pgr_data->current_edge = 0;

        funcctx->user_fctx = pgr_data;
        funcctx->max_calls = result->num_edges;  // Return one row per selected edge

        SPI_finish();
        MemoryContextSwitchTo(oldcontext);
    }

    funcctx = SRF_PERCALL_SETUP();

    if (funcctx->call_cntr < funcctx->max_calls) {
        pgr_result_data *pgr_data = (pgr_result_data *) funcctx->user_fctx;
        pcst_result_t *result = pgr_data->result;
        HeapTuple tuple;
        Datum values[5];
        bool nulls[5] = {false, false, false, false, false};

        // Get the current edge index from result
        int edge_idx = funcctx->call_cntr;
        if (edge_idx >= result->num_edges) {
            SRF_RETURN_DONE(funcctx);
        }

        // Get the internal edge index from the result
        int internal_edge_index = result->result_edges[edge_idx];

        // Map to original edge ID and get source/target/cost
        int edge_id = -1;
        int source_id = -1;
        int target_id = -1;
        double cost = 0.0;

        if (internal_edge_index >= 0 && internal_edge_index < pgr_data->num_edges) {
            edge_id = pgr_data->index_to_edge_id[internal_edge_index];
            source_id = pgr_data->edge_sources[internal_edge_index];
            target_id = pgr_data->edge_targets[internal_edge_index];
            cost = pgr_data->edge_costs[internal_edge_index];
        }

        // Return row: seq, edge, source, target, cost
        values[0] = Int32GetDatum(edge_idx + 1);  // seq (1-based)
        values[1] = Int64GetDatum((int64) edge_id);  // edge ID
        values[2] = Int64GetDatum((int64) source_id);  // source node ID
        values[3] = Int64GetDatum((int64) target_id);  // target node ID
        values[4] = Float8GetDatum(cost);  // edge cost

        tuple = heap_form_tuple(funcctx->tuple_desc, values, nulls);

        SRF_RETURN_NEXT(funcctx, HeapTupleGetDatum(tuple));
    } else {
        // Clean up
        pgr_result_data *pgr_data = (pgr_result_data *) funcctx->user_fctx;
        if (pgr_data && pgr_data->result) {
            pcst_free_result(pgr_data->result);
        }

        SRF_RETURN_DONE(funcctx);
    }
}