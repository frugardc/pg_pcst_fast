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
    text **index_to_node_id;     // Maps internal index -> original node ID (text)
    text **index_to_edge_id;     // Maps internal index -> original edge ID (text)
    text **edge_sources;         // Original source node IDs for edges (text)
    text **edge_targets;         // Original target node IDs for edges (text)
    double *edge_costs;          // Edge costs
    int num_nodes;               // Number of unique nodes
    int num_edges;               // Number of edges
    pcst_result_t *result;       // PCST result with internal indices
    int current_edge;            // Current edge index for row-by-row return
    int verbosity;               // Verbosity level for debugging
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

/* Hash table entry structure for node ID mapping (using text pointer keys) */
typedef struct {
    text *node_id;  // Key (pointer to text)
    int index;      // Value
} node_map_entry;

/* Forward declaration */
static int text_cmp(const text *t1, const text *t2);

/* Hash function for text pointer keys - hashes the text content */
static uint32 node_id_hash(const void *key, Size keysize) {
    const text **tkey_ptr = (const text **) key;
    const text *tkey = *tkey_ptr;
    // Simple hash function: djb2 algorithm
    const unsigned char *data = (const unsigned char *) VARDATA(tkey);
    int len = VARSIZE(tkey) - VARHDRSZ;
    uint32 hash = 5381;
    for (int i = 0; i < len; i++) {
        hash = ((hash << 5) + hash) + data[i]; /* hash * 33 + c */
    }
    return hash;
}

/* Match function for text pointer keys - compares text content */
static int node_id_match(const void *key1, const void *key2, Size keysize) {
    const text **k1_ptr = (const text **) key1;
    const text **k2_ptr = (const text **) key2;
    const text *k1 = *k1_ptr;
    const text *k2 = *k2_ptr;
    return (text_cmp(k1, k2) == 0) ? 0 : 1;
}

/* Helper function to compare two text values */
static int text_cmp(const text *t1, const text *t2) {
    int len1 = VARSIZE(t1) - VARHDRSZ;
    int len2 = VARSIZE(t2) - VARHDRSZ;
    int minlen = (len1 < len2) ? len1 : len2;
    int cmp = memcmp(VARDATA(t1), VARDATA(t2), minlen);
    if (cmp != 0)
        return cmp;
    return len1 - len2;
}

/* Helper function to convert any Datum to text */
/* Always returns a text value allocated in the current memory context */
static text *datum_to_text(Datum value, Oid type) {
    if (type == TEXTOID) {
        // For text type, we need to make a copy to ensure it's in the current memory context
        text *input_text = DatumGetTextP(value);
        int len = VARSIZE(input_text);
        text *result = (text *) palloc(len);
        memcpy(result, input_text, len);
        return result;
    } else {
        // Use the type's output function to get a string, then convert to text
        Oid output_func;
        bool isvarlena;
        getTypeOutputInfo(type, &output_func, &isvarlena);
        char *str = OidOutputFunctionCall(output_func, value);
        text *result = cstring_to_text(str);
        pfree(str);
        return result;
    }
}

/* Helper function to find or add node ID to mapping using hash table */
static int get_node_index(HTAB *node_map, int *next_index, text *node_id, text ***index_to_node_id, int verbosity) {
    bool found;
    node_map_entry *entry;
    int node_id_len = VARSIZE(node_id);

    // Make a copy of the node_id text for storage
    text *node_id_copy = (text *) palloc(node_id_len);
    memcpy(node_id_copy, node_id, node_id_len);

    // Search for existing entry using the text pointer as key
    entry = (node_map_entry *) hash_search(node_map, &node_id_copy, HASH_ENTER, &found);

    if (!found) {
        // New entry - set the index
        int new_index = (*next_index)++;
        entry->node_id = node_id_copy;  // Store the copy
        entry->index = new_index;

        // Reallocate index_to_node_id array if needed
        *index_to_node_id = (text **) repalloc(*index_to_node_id, (*next_index) * sizeof(text *));
        (*index_to_node_id)[new_index] = node_id_copy;

        if (verbosity > 1) {
            char *node_id_str = text_to_cstring(node_id_copy);
            elog(INFO, "get_node_index: NEW node_id=%s -> index=%d", node_id_str, new_index);
            pfree(node_id_str);
        }
    } else {
        // Entry already exists, free the copy we made
        pfree(node_id_copy);
        if (verbosity > 1) {
            char *node_id_str = text_to_cstring(entry->node_id);
            elog(INFO, "get_node_index: FOUND node_id=%s -> index=%d", node_id_str, entry->index);
            pfree(node_id_str);
        }
    }

    return entry->index;
}

/* pg_routing-style PCST function that takes SQL queries */
Datum pcst_fast_pgr(PG_FUNCTION_ARGS) {
    text *edges_sql = PG_GETARG_TEXT_P(0);
    text *nodes_sql = PG_GETARG_TEXT_P(1);
    text *root_id = PG_ARGISNULL(2) ? NULL : PG_GETARG_TEXT_P(2);  // Original node ID (text), or NULL for auto-select
    int num_clusters = PG_ARGISNULL(3) ? 1 : PG_GETARG_INT32(3);
    text *pruning_text = PG_ARGISNULL(4) ? NULL : PG_GETARG_TEXT_P(4);
    int verbosity = PG_ARGISNULL(5) ? 0 : PG_GETARG_INT32(5);

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
        text **edge_ids = NULL;
        int *edge_sources = NULL;  // Internal indices
        int *edge_targets = NULL;   // Internal indices
        double *edge_costs = NULL;
        text **index_to_node_id = NULL;
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

        // Initialize hash table for node ID mapping (using text pointer keys)
        memset(&hash_ctl, 0, sizeof(hash_ctl));
        hash_ctl.keysize = sizeof(text *);  // Key is a pointer to text
        hash_ctl.entrysize = sizeof(node_map_entry);  // Entry contains node_id (text*) and index
        hash_ctl.hash = node_id_hash;
        hash_ctl.match = node_id_match;
        hash_ctl.hcxt = CurrentMemoryContext;
        node_map = hash_create("node_id_map", 1024, &hash_ctl,
                               HASH_ELEM | HASH_FUNCTION | HASH_COMPARE | HASH_CONTEXT);

        // Allocate arrays
        edge_ids = (text **) palloc(max_edges * sizeof(text *));
        edge_sources = (int *) palloc(max_edges * sizeof(int));  // Internal indices
        edge_targets = (int *) palloc(max_edges * sizeof(int));   // Internal indices
        edge_costs = (double *) palloc(max_edges * sizeof(double));
        // Allocate initial array - will be reallocated as needed
        index_to_node_id = (text **) palloc(1024 * sizeof(text *));

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
            edge_ids = (text **) repalloc(edge_ids, max_edges * sizeof(text *));
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

            // Convert IDs to text (handles both integer and text input)
            Oid edge_id_type = SPI_gettypeid(edges_tupdesc, 1);
            Oid source_id_type = SPI_gettypeid(edges_tupdesc, 2);
            Oid target_id_type = SPI_gettypeid(edges_tupdesc, 3);

            // Convert IDs to text - datum_to_text already makes a copy in current memory context
            text *edge_id_text = datum_to_text(edge_id_datum, edge_id_type);
            text *source_id_text = datum_to_text(source_datum, source_id_type);
            text *target_id_text = datum_to_text(target_datum, target_id_type);

            double cost = DatumGetFloat8(cost_datum);

            // Store the edge_id_text directly - it's already a copy in the current memory context
            // No need for another memcpy since datum_to_text already handles the copy
            edge_ids[i] = edge_id_text;

            // Verify the stored text is valid
            if (edge_ids[i] == NULL || VARSIZE(edge_ids[i]) < VARHDRSZ) {
                char *edge_id_str = edge_id_text ? text_to_cstring(edge_id_text) : NULL;
                ereport(ERROR,
                        (errcode(ERRCODE_INTERNAL_ERROR),
                         errmsg("Invalid edge_id: '%s', len=%d",
                                edge_id_str ? edge_id_str : "NULL",
                                edge_ids[i] ? VARSIZE(edge_ids[i]) : 0)));
                if (edge_id_str) pfree(edge_id_str);
            }

            // Debug: verify edge ID storage
            if (verbosity > 1) {
                char *edge_id_str = text_to_cstring(edge_ids[i]);
                elog(INFO, "pgr_pcst_fast: Stored edge[%lu] id: '%s', ptr=%p, len=%d",
                     (unsigned long) i, edge_id_str, (void *) edge_ids[i], VARSIZE(edge_ids[i]));
                pfree(edge_id_str);
            }

            edge_sources[i] = get_node_index(node_map, &next_node_index, source_id_text, &index_to_node_id, verbosity);
            edge_targets[i] = get_node_index(node_map, &next_node_index, target_id_text, &index_to_node_id, verbosity);
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
            Oid node_id_type = SPI_gettypeid(nodes_tupdesc, 1);

            if (verbosity > 0) {
                elog(INFO, "pgr_pcst_fast: Processing %lu nodes from nodes query", SPI_processed);
            }

            int nodes_matched = 0;
            int nodes_not_found = 0;

            for (unsigned long i = 0; i < SPI_processed; i++) {
                HeapTuple tuple = SPI_tuptable->vals[i];
                bool isnull;
                Datum node_id_datum = SPI_getbinval(tuple, nodes_tupdesc, 1, &isnull);
                Datum prize_datum = SPI_getbinval(tuple, nodes_tupdesc, 2, &isnull);

                if (isnull)
                    continue;  // Skip NULL values

                text *node_id_text = datum_to_text(node_id_datum, node_id_type);
                double prize = DatumGetFloat8(prize_datum);

                // Debug: log the node ID we're looking for (first few only)
                if (verbosity > 0 && i < 5) {
                    char *node_id_str = text_to_cstring(node_id_text);
                    elog(INFO, "pgr_pcst_fast: Looking up node_id='%s' (len=%d, prize=%.2f)",
                         node_id_str, VARSIZE(node_id_text) - VARHDRSZ, prize);
                    pfree(node_id_str);
                }

                // Find node index using hash table
                // Try hash_search first, but if it fails, fall back to manual iteration
                bool found = false;
                node_map_entry *entry = NULL;

                // First try: use hash_search with the text pointer
                text *node_id_key = node_id_text;
                entry = (node_map_entry *) hash_search(node_map, &node_id_key, HASH_FIND, &found);

                // Fallback: if hash_search fails, manually iterate through hash table
                // This is slower but more reliable if there's a hash function issue
                if (!found || entry == NULL) {
                    HASH_SEQ_STATUS hash_seq;
                    node_map_entry *hentry;

                    hash_seq_init(&hash_seq, node_map);
                    while ((hentry = (node_map_entry *) hash_seq_search(&hash_seq)) != NULL) {
                        if (hentry->node_id != NULL && text_cmp(hentry->node_id, node_id_text) == 0) {
                            entry = hentry;
                            found = true;
                            break;
                        }
                    }
                    hash_seq_term(&hash_seq);
                }

                // Debug: log lookup result (first few only)
                if (verbosity > 0 && i < 5) {
                    char *node_id_str = text_to_cstring(node_id_text);
                    if (found && entry) {
                        char *stored_id_str = text_to_cstring(entry->node_id);
                        elog(INFO, "pgr_pcst_fast: Hash lookup FOUND: looking_for='%s', stored='%s', index=%d",
                             node_id_str, stored_id_str, entry->index);
                        pfree(stored_id_str);
                    } else {
                        elog(INFO, "pgr_pcst_fast: Hash lookup NOT FOUND: node_id='%s'", node_id_str);
                    }
                    pfree(node_id_str);
                }

                if (found && entry != NULL) {
                    int node_index = entry->index;
                    if (node_index >= 0 && node_index < num_nodes) {
                        node_prizes[node_index] = prize;
                        nodes_matched++;
                        if (verbosity > 0 && i < 10) {  // Only log first 10 for large datasets
                            char *node_id_str = text_to_cstring(node_id_text);
                            elog(INFO, "pgr_pcst_fast: Setting prize for node_id=%s (index=%d) to %.2f",
                                 node_id_str, node_index, prize);
                            pfree(node_id_str);
                        }
                    } else {
                        if (verbosity > 0) {
                            char *node_id_str = text_to_cstring(node_id_text);
                            elog(WARNING, "pgr_pcst_fast: node_id=%s mapped to invalid index %d (num_nodes=%d)",
                                 node_id_str, node_index, num_nodes);
                            pfree(node_id_str);
                        }
                    }
                } else {
                    // Node in nodes query but not in edges - this is OK, just skip it
                    nodes_not_found++;
                    if (verbosity > 0 && i < 10) {  // Only log first 10 for large datasets
                        char *node_id_str = text_to_cstring(node_id_text);
                        elog(INFO, "pgr_pcst_fast: node_id=%s in nodes query but not in edges, skipping (prize=%.2f)",
                             node_id_str, prize);
                        pfree(node_id_str);
                    }
                }

                // Free the temporary node_id_text (it was created by datum_to_text)
                pfree(node_id_text);
            }

            // Summary of node matching
            if (verbosity > 0) {
                elog(INFO, "pgr_pcst_fast: Nodes query summary: %lu rows processed, %d matched, %d not found in edges",
                     SPI_processed, nodes_matched, nodes_not_found);
            }

            // Debug: Log node prizes with better visibility
            if (verbosity > 0) {
                elog(INFO, "pgr_pcst_fast: Total nodes processed: %d", num_nodes);

                // Count nodes with prizes > 0
                int nodes_with_prizes = 0;
                double total_prize_sum = 0.0;
                double max_prize = 0.0;
                int max_prize_index = -1;

                for (int i = 0; i < num_nodes; i++) {
                    if (node_prizes[i] > 0.0) {
                        nodes_with_prizes++;
                        total_prize_sum += node_prizes[i];
                        if (node_prizes[i] > max_prize) {
                            max_prize = node_prizes[i];
                            max_prize_index = i;
                        }
                    }
                }

                elog(INFO, "pgr_pcst_fast: Prize statistics: %d nodes with prizes > 0, total prize sum=%.2f, max prize=%.2f",
                     nodes_with_prizes, total_prize_sum, max_prize);

                // Show first 10 nodes (always)
                elog(INFO, "pgr_pcst_fast: First 10 nodes:");
                for (int i = 0; i < num_nodes && i < 10; i++) {
                    char *node_id_str = text_to_cstring(index_to_node_id[i]);
                    elog(INFO, "pgr_pcst_fast:   node[%d] (id=%s) prize=%.2f",
                         i, node_id_str, node_prizes[i]);
                    pfree(node_id_str);
                }

                // Show nodes with prizes > 0 (up to 20)
                if (nodes_with_prizes > 0) {
                    elog(INFO, "pgr_pcst_fast: Nodes with prizes > 0 (showing up to 20):");
                    int shown = 0;
                    for (int i = 0; i < num_nodes && shown < 20; i++) {
                        if (node_prizes[i] > 0.0) {
                            char *node_id_str = text_to_cstring(index_to_node_id[i]);
                            elog(INFO, "pgr_pcst_fast:   node[%d] (id=%s) prize=%.2f",
                                 i, node_id_str, node_prizes[i]);
                            pfree(node_id_str);
                            shown++;
                        }
                    }
                    if (nodes_with_prizes > 20) {
                        elog(INFO, "pgr_pcst_fast:   ... and %d more nodes with prizes > 0", nodes_with_prizes - 20);
                    }
                } else {
                    elog(WARNING, "pgr_pcst_fast: WARNING - No nodes have prizes > 0! All prizes are 0.00");
                }

                // Show the node with maximum prize
                if (max_prize_index >= 0) {
                    char *max_prize_id_str = text_to_cstring(index_to_node_id[max_prize_index]);
                    elog(INFO, "pgr_pcst_fast: Node with maximum prize: node[%d] (id=%s) prize=%.2f",
                         max_prize_index, max_prize_id_str, max_prize);
                    pfree(max_prize_id_str);
                }
            }
        } else {
            // No nodes query results - all prizes remain 0
            if (verbosity > 0) {
                elog(WARNING, "pgr_pcst_fast: nodes query returned no results, all node prizes are 0");
            }
        }

        // Map root node ID to index
        // Handle special case: -1 or '-1' means auto-select (no root)
        if (root_id != NULL) {
            char *root_id_str = text_to_cstring(root_id);
            // Check if root_id is -1 or '-1' (auto-select)
            if (strcmp(root_id_str, "-1") == 0) {
                pfree(root_id_str);
                root_index = -1;  // Auto-select
            } else {
                bool found;
                node_map_entry *entry = (node_map_entry *) hash_search(node_map, &root_id, HASH_FIND, &found);

                if (!found || entry == NULL) {
                    ereport(ERROR,
                            (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                             errmsg("root node ID '%s' not found in edges", root_id_str)));
                }
                root_index = entry->index;
                pfree(root_id_str);
            }
        }

        // Convert pruning string to enum
        if (pruning_text == NULL) {
            pruning_str = "simple";  // Default
        } else {
            pruning_str = text_to_cstring(pruning_text);
        }
        if (strcmp(pruning_str, "none") == 0)
            pruning_method = 0;
        else if (strcmp(pruning_str, "simple") == 0)
            pruning_method = 1;
        else if (strcmp(pruning_str, "gw") == 0)
            pruning_method = 2;
        else if (strcmp(pruning_str, "strong") == 0)
            pruning_method = 3;
        else
            pruning_method = 1; // default to simple

        // Debug: Verify node prizes and edges
        if (verbosity > 0) {
            elog(INFO, "pgr_pcst_fast: num_nodes=%d, num_edges=%d, root_index=%d",
                 num_nodes, num_edges, root_index);

            // Show first 10 nodes
            elog(INFO, "pgr_pcst_fast: First 10 nodes:");
            for (int i = 0; i < num_nodes && i < 10; i++) {
                char *node_id_str = text_to_cstring(index_to_node_id[i]);
                elog(INFO, "  node[%d] (id=%s) prize=%.2f",
                     i, node_id_str, node_prizes[i]);
                pfree(node_id_str);
            }

            // Show edge statistics
            double total_edge_cost = 0.0;
            double min_edge_cost = (num_edges > 0) ? edge_costs[0] : 0.0;
            double max_edge_cost = (num_edges > 0) ? edge_costs[0] : 0.0;
            for (int i = 0; i < num_edges; i++) {
                total_edge_cost += edge_costs[i];
                if (edge_costs[i] < min_edge_cost) min_edge_cost = edge_costs[i];
                if (edge_costs[i] > max_edge_cost) max_edge_cost = edge_costs[i];
            }
            elog(INFO, "pgr_pcst_fast: Edge statistics: total=%d edges, total cost=%.2f, min=%.2f, max=%.2f, avg=%.2f",
                 num_edges, total_edge_cost, min_edge_cost, max_edge_cost,
                 num_edges > 0 ? total_edge_cost / num_edges : 0.0);

            // Show first 10 edges
            elog(INFO, "pgr_pcst_fast: First 10 edges:");
            for (int i = 0; i < num_edges && i < 10; i++) {
                char *edge_id_str = text_to_cstring(edge_ids[i]);
                char *source_id_str = text_to_cstring(index_to_node_id[edge_sources[i]]);
                char *target_id_str = text_to_cstring(index_to_node_id[edge_targets[i]]);
                elog(INFO, "  edge[%d] (id=%s): %s->%s cost=%.2f",
                     i, edge_id_str, source_id_str, target_id_str, edge_costs[i]);
                pfree(edge_id_str);
                pfree(source_id_str);
                pfree(target_id_str);
            }

            // Show last 5 edges (if there are more than 10)
            if (num_edges > 10) {
                elog(INFO, "pgr_pcst_fast: Last 5 edges:");
                int start = (num_edges > 5) ? num_edges - 5 : 10;
                for (int i = start; i < num_edges; i++) {
                    char *edge_id_str = text_to_cstring(edge_ids[i]);
                    char *source_id_str = text_to_cstring(index_to_node_id[edge_sources[i]]);
                    char *target_id_str = text_to_cstring(index_to_node_id[edge_targets[i]]);
                    elog(INFO, "  edge[%d] (id=%s): %s->%s cost=%.2f",
                         i, edge_id_str, source_id_str, target_id_str, edge_costs[i]);
                    pfree(edge_id_str);
                    pfree(source_id_str);
                    pfree(target_id_str);
                }
            }
        }

        // PRESERVE the original edge_costs BEFORE calling the algorithm
        // The algorithm may modify the costs array in place, even if we pass a copy
        // So we need to save the original values first
        MemoryContext ec_oldctx = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);
        double *edge_costs_original = (double *) palloc(num_edges * sizeof(double));
        MemoryContextSwitchTo(ec_oldctx);
        memcpy(edge_costs_original, edge_costs, num_edges * sizeof(double));

        // Make a copy of edge_costs for the algorithm to modify
        double *edge_costs_copy = (double *) palloc(num_edges * sizeof(double));
        memcpy(edge_costs_copy, edge_costs, num_edges * sizeof(double));

        // Call the C function (may modify the costs array)
        pcst_result_t *result = pcst_solve(
            edge_sources, edge_targets, edge_costs_copy, num_edges,
            node_prizes, num_nodes,
            root_index, num_clusters, pruning_method, verbosity
        );

        // Free the copy after algorithm completes
        pfree(edge_costs_copy);

        if (!result || !result->success) {
            const char *error_msg = result ? result->error_message : "Unknown error";
            if (result) pcst_free_result(result);
            SPI_finish();
            ereport(ERROR, (errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
                           errmsg("PCST algorithm failed: %s", error_msg)));
        }

        // Store original edge source/target IDs for result rows
        // Map internal indices back to original node IDs (text)
        /* Ensure all long-lived data is copied into the multi-call context */
        MemoryContext data_mctx_prev = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);

        text **node_id_copies = (text **) palloc(num_nodes * sizeof(text *));
        for (int i = 0; i < num_nodes; i++) {
            if (index_to_node_id[i] != NULL && VARSIZE(index_to_node_id[i]) >= VARHDRSZ) {
                int len = VARSIZE(index_to_node_id[i]);
                node_id_copies[i] = (text *) palloc(len);
                memcpy(node_id_copies[i], index_to_node_id[i], len);
            } else {
                node_id_copies[i] = NULL;
            }
        }

        text **original_edge_sources = (text **) palloc(num_edges * sizeof(text *));
        text **original_edge_targets = (text **) palloc(num_edges * sizeof(text *));

        for (int i = 0; i < num_edges; i++) {
            if (edge_sources[i] >= 0 && edge_sources[i] < num_nodes) {
                original_edge_sources[i] = node_id_copies[edge_sources[i]];
            } else {
                original_edge_sources[i] = NULL;
            }
            if (edge_targets[i] >= 0 && edge_targets[i] < num_nodes) {
                original_edge_targets[i] = node_id_copies[edge_targets[i]];
            } else {
                original_edge_targets[i] = NULL;
            }
        }

        // Store result with mappings
        // Make a deep copy of edge_ids array to ensure pointers are stable
        text **edge_ids_copy = (text **) palloc(num_edges * sizeof(text *));
        for (int i = 0; i < num_edges; i++) {
            if (edge_ids[i] != NULL && VARSIZE(edge_ids[i]) >= VARHDRSZ) {
                // Make a deep copy of each text object
                int len = VARSIZE(edge_ids[i]);
                edge_ids_copy[i] = (text *) palloc(len);
                memcpy(edge_ids_copy[i], edge_ids[i], len);
                // Verify the copy
                if (VARSIZE(edge_ids_copy[i]) != len) {
                    ereport(ERROR,
                            (errcode(ERRCODE_INTERNAL_ERROR),
                             errmsg("Failed to copy edge_id[%d]", i)));
                }
            } else {
                edge_ids_copy[i] = NULL;
            }
        }

        pgr_data = (pgr_result_data *) palloc(sizeof(pgr_result_data));
        pgr_data->result = result;
        pgr_data->num_nodes = num_nodes;
        pgr_data->num_edges = num_edges;
        pgr_data->index_to_node_id = node_id_copies;
        pgr_data->index_to_edge_id = edge_ids_copy;  // Use the deep copy
        pgr_data->edge_sources = original_edge_sources;
        pgr_data->edge_targets = original_edge_targets;
        pgr_data->edge_costs = edge_costs_original;  // Use the preserved original costs
        pgr_data->current_edge = 0;
        pgr_data->verbosity = verbosity;

        // Debug: Verify edge_costs and edge_ids arrays before storing
        if (verbosity > 0) {
            elog(INFO, "pgr_pcst_fast: Storing edge_costs_original array (num_edges=%d, showing first 10):", num_edges);
            for (int i = 0; i < num_edges && i < 10; i++) {
                elog(INFO, "  edge_costs_original[%d] = %.2f", i, edge_costs_original[i]);
            }
            if (num_edges > 10) {
                elog(INFO, "  ... and %d more edges", num_edges - 10);
            }
            elog(INFO, "pgr_pcst_fast: Storing edge_ids_copy array (num_edges=%d, showing first 10):", num_edges);
            for (int i = 0; i < num_edges && i < 10; i++) {
                if (edge_ids_copy[i] != NULL) {
                    char *edge_id_str = text_to_cstring(edge_ids_copy[i]);
                    elog(INFO, "  edge_ids_copy[%d] = '%s', ptr=%p, size=%d",
                         i, edge_id_str, (void *) edge_ids_copy[i], VARSIZE(edge_ids_copy[i]));
                    pfree(edge_id_str);
                } else {
                    elog(INFO, "  edge_ids_copy[%d] = NULL", i);
                }
            }
            if (num_edges > 10) {
                elog(INFO, "  ... and %d more edge IDs", num_edges - 10);
            }
            elog(INFO, "pgr_pcst_fast: Result contains %d edges:", result->num_edges);
            for (int i = 0; i < result->num_edges && i < 10; i++) {
                elog(INFO, "  result_edges[%d] = %d", i, result->result_edges[i]);
            }
        }

        funcctx->user_fctx = pgr_data;
        funcctx->max_calls = result->num_edges;  // Return one row per selected edge

        MemoryContextSwitchTo(data_mctx_prev);

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
        int verbosity = pgr_data->verbosity;

        // Get the current edge index from result
        int edge_idx = funcctx->call_cntr;
        if (edge_idx >= result->num_edges) {
            SRF_RETURN_DONE(funcctx);
        }

        // Get the internal edge index from the result
        int internal_edge_index = result->result_edges[edge_idx];

        // Map to original edge ID and get source/target/cost (all as text)
        text *edge_id_text = NULL;
        text *source_id_text = NULL;
        text *target_id_text = NULL;
        double cost = 0.0;

        if (internal_edge_index >= 0 && internal_edge_index < pgr_data->num_edges) {
            // Debug: check what's in the array before retrieving
            if (verbosity > 0) {
                if (pgr_data->index_to_edge_id[internal_edge_index] != NULL) {
                    char *debug_str = text_to_cstring(pgr_data->index_to_edge_id[internal_edge_index]);
                    elog(INFO, "pgr_pcst_fast: Before retrieval - index_to_edge_id[%d] = '%s', ptr=%p, size=%d",
                         internal_edge_index, debug_str,
                         (void *) pgr_data->index_to_edge_id[internal_edge_index],
                         VARSIZE(pgr_data->index_to_edge_id[internal_edge_index]));
                    pfree(debug_str);
                } else {
                    elog(INFO, "pgr_pcst_fast: Before retrieval - index_to_edge_id[%d] = NULL", internal_edge_index);
                }
            }

            edge_id_text = pgr_data->index_to_edge_id[internal_edge_index];
            source_id_text = pgr_data->edge_sources[internal_edge_index];
            target_id_text = pgr_data->edge_targets[internal_edge_index];

            // Debug: check edge_costs array before retrieval
            if (verbosity > 0) {
                elog(INFO, "pgr_pcst_fast: Before retrieval - edge_costs[%d] = %.2f (array size check: num_edges=%d)",
                     internal_edge_index,
                     (internal_edge_index < pgr_data->num_edges) ? pgr_data->edge_costs[internal_edge_index] : -999.0,
                     pgr_data->num_edges);
            }

            cost = pgr_data->edge_costs[internal_edge_index];

            // Safety check: ensure pointers are valid and text structures are intact
            if (edge_id_text == NULL || source_id_text == NULL || target_id_text == NULL) {
                if (verbosity > 0) {
                    elog(WARNING, "pgr_pcst_fast: NULL pointer at edge index %d (internal_index=%d)",
                         edge_idx, internal_edge_index);
                }
            } else {
                // Verify text structures are valid
                if (VARSIZE(edge_id_text) < VARHDRSZ) {
                    if (verbosity > 0) {
                        elog(WARNING, "pgr_pcst_fast: Invalid edge_id_text at index %d (size=%d)",
                             internal_edge_index, VARSIZE(edge_id_text));
                    }
                    edge_id_text = NULL;  // Mark as invalid
                }
                if (VARSIZE(source_id_text) < VARHDRSZ) {
                    if (verbosity > 0) {
                        elog(WARNING, "pgr_pcst_fast: Invalid source_id_text at index %d (size=%d)",
                             internal_edge_index, VARSIZE(source_id_text));
                    }
                    source_id_text = NULL;  // Mark as invalid
                }
                if (VARSIZE(target_id_text) < VARHDRSZ) {
                    if (verbosity > 0) {
                        elog(WARNING, "pgr_pcst_fast: Invalid target_id_text at index %d (size=%d)",
                             internal_edge_index, VARSIZE(target_id_text));
                    }
                    target_id_text = NULL;  // Mark as invalid
                }
            }

            // Debug: log retrieval with detailed validation
            if (verbosity > 0) {
                char *edge_id_debug = NULL;
                if (edge_id_text != NULL && VARSIZE(edge_id_text) >= VARHDRSZ) {
                    edge_id_debug = text_to_cstring(edge_id_text);
                }
                elog(INFO, "pgr_pcst_fast: Returning edge_idx=%d, internal_index=%d, edge_id='%s', edge_id_ptr=%p, edge_id_size=%d, cost=%.2f",
                     edge_idx, internal_edge_index,
                     edge_id_debug ? edge_id_debug : "NULL",
                     (void *) edge_id_text,
                     edge_id_text ? VARSIZE(edge_id_text) : 0,
                     cost);
                if (edge_id_debug) pfree(edge_id_debug);
            }
        } else {
            // Invalid edge index
            if (verbosity > 0) {
                elog(WARNING, "pgr_pcst_fast: Invalid edge index %d (num_edges=%d, edge_idx=%d)",
                     internal_edge_index, pgr_data->num_edges, edge_idx);
            }
        }

        // Return row: seq, edge, source, target, cost
        values[0] = Int32GetDatum(edge_idx + 1);  // seq (1-based)

        // Convert text pointers to Datums properly
        // Use PointerGetDatum for text pointers - PostgreSQL will handle the conversion
        if (edge_id_text != NULL && VARSIZE(edge_id_text) >= VARHDRSZ) {
            values[1] = PointerGetDatum(edge_id_text);
            nulls[1] = false;
        } else {
            values[1] = (Datum) 0;
            nulls[1] = true;
        }

        if (source_id_text != NULL && VARSIZE(source_id_text) >= VARHDRSZ) {
            values[2] = PointerGetDatum(source_id_text);
            nulls[2] = false;
        } else {
            values[2] = (Datum) 0;
            nulls[2] = true;
        }

        if (target_id_text != NULL && VARSIZE(target_id_text) >= VARHDRSZ) {
            values[3] = PointerGetDatum(target_id_text);
            nulls[3] = false;
        } else {
            values[3] = (Datum) 0;
            nulls[3] = true;
        }

        values[4] = Float8GetDatum(cost);  // edge cost
        nulls[4] = false;  // cost is never NULL (defaults to 0.0)

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