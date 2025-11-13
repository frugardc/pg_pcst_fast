#ifndef PCST_FAST_C_WRAPPER_H
#define PCST_FAST_C_WRAPPER_H

#ifdef __cplusplus
extern "C" {
#endif

// C structure to hold the result
typedef struct {
    int* result_nodes;
    int* result_edges;
    int num_nodes;
    int num_edges;
    int success;
    char error_message[256];
} pcst_result_t;

// C function to solve PCST
pcst_result_t* pcst_solve(
    int* edge_sources,
    int* edge_targets,
    double* edge_costs,
    int num_edges,
    double* node_prizes,
    int num_nodes,
    int root_node,
    int target_num_active_clusters,
    int pruning_method,
    int verbosity_level
);

// Free the result structure
void pcst_free_result(pcst_result_t* result);

#ifdef __cplusplus
}
#endif

#endif