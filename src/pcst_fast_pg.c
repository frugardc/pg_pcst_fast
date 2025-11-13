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
#include "pcst_fast_c_wrapper.h"

PG_MODULE_MAGIC;

/* Function declarations */
PG_FUNCTION_INFO_V1(pcst_fast_pg);

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