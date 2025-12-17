#include "pcst_fast_c_wrapper.h"
#include "pcst_fast.h"
#include <cstring>
#include <cstdlib>
#include <vector>
#include <utility>

using namespace cluster_approx;
using std::vector;
using std::pair;
using std::make_pair;

// Simple output function for C wrapper
static void default_output_function(const char* message) {
    // For PostgreSQL extension, we might want to use elog here
    // For now, just ignore output to avoid issues
}

extern "C" {

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
) {
    pcst_result_t* result = (pcst_result_t*)malloc(sizeof(pcst_result_t));
    if (!result) {
        return nullptr;
    }

    // Initialize result
    result->result_nodes = nullptr;
    result->result_edges = nullptr;
    result->num_nodes = 0;
    result->num_edges = 0;
    result->success = 0;
    strcpy(result->error_message, "");

    try {
        // Validate root node if specified
        if (root_node >= 0) {
            if (root_node >= num_nodes) {
                snprintf(result->error_message, sizeof(result->error_message),
                        "Root node %d is out of range. Valid range is 0-%d",
                        root_node, num_nodes - 1);
                return result;
            }

            // Check if root node appears in any edge (connectivity check)
            bool root_connected = false;
            for (int i = 0; i < num_edges; i++) {
                if (edge_sources[i] == root_node || edge_targets[i] == root_node) {
                    root_connected = true;
                    break;
                }
            }

            if (!root_connected) {
                snprintf(result->error_message, sizeof(result->error_message),
                        "Root node %d is not connected to any edges", root_node);
                return result;
            }
        }

        // Convert input data to C++ format
        vector<pair<int, int>> edges;
        vector<double> prizes;
        vector<double> costs;

        // Build edges vector and validate node IDs
        int max_node_id = -1;
        for (int i = 0; i < num_edges; i++) {
            if (edge_sources[i] < 0 || edge_targets[i] < 0) {
                snprintf(result->error_message, sizeof(result->error_message),
                        "Edge %d has negative node ID: source=%d, target=%d",
                        i, edge_sources[i], edge_targets[i]);
                return result;
            }

            max_node_id = std::max(max_node_id, std::max(edge_sources[i], edge_targets[i]));
            edges.push_back(make_pair(edge_sources[i], edge_targets[i]));
            costs.push_back(edge_costs[i]);
        }

        // Validate that all edge node IDs have corresponding prizes
        if (max_node_id >= num_nodes) {
            snprintf(result->error_message, sizeof(result->error_message),
                    "Edge references node %d but only %d prizes provided (valid range: 0-%d)",
                    max_node_id, num_nodes, num_nodes - 1);
            return result;
        }

        // Build prizes vector
        for (int i = 0; i < num_nodes; i++) {
            prizes.push_back(node_prizes[i]);
        }

        // Convert pruning method
        PCSTFast::PruningMethod pruning = PCSTFast::kGWPruning;
        switch (pruning_method) {
            case 0: pruning = PCSTFast::kNoPruning; break;
            case 1: pruning = PCSTFast::kSimplePruning; break;
            case 2: pruning = PCSTFast::kGWPruning; break;
            case 3: pruning = PCSTFast::kStrongPruning; break;
            default: pruning = PCSTFast::kGWPruning; break;
        }

        // Handle root node (-1 means no root in C++ API)
        int cpp_root = (root_node < 0) ? PCSTFast::kNoRoot : root_node;

        // Add detailed logging for debugging
        if (verbosity_level > 0) {
            snprintf(result->error_message, sizeof(result->error_message),
                    "Debug: Creating solver with %d edges, %d nodes, root=%d, clusters=%d",
                    num_edges, num_nodes, cpp_root, target_num_active_clusters);
        }

        // Create PCST solver
        PCSTFast solver(edges, prizes, costs, cpp_root, target_num_active_clusters,
                       pruning, verbosity_level, default_output_function);

        // Add more detailed error reporting
        if (verbosity_level > 0) {
            strcpy(result->error_message, "Debug: Solver created, calling run()");
        }

        // Solve
        vector<int> result_nodes_vec;
        vector<int> result_edges_vec;

        bool success = solver.run(&result_nodes_vec, &result_edges_vec);

        if (success) {
            // Allocate memory for results
            result->num_nodes = result_nodes_vec.size();
            result->num_edges = result_edges_vec.size();

            if (result->num_nodes > 0) {
                result->result_nodes = (int*)malloc(result->num_nodes * sizeof(int));
                if (!result->result_nodes) {
                    strcpy(result->error_message, "Failed to allocate memory for result nodes");
                    return result;
                }
                for (int i = 0; i < result->num_nodes; i++) {
                    result->result_nodes[i] = result_nodes_vec[i];
                }
            }

            if (result->num_edges > 0) {
                result->result_edges = (int*)malloc(result->num_edges * sizeof(int));
                if (!result->result_edges) {
                    strcpy(result->error_message, "Failed to allocate memory for result edges");
                    if (result->result_nodes) {
                        free(result->result_nodes);
                        result->result_nodes = nullptr;
                    }
                    return result;
                }
                for (int i = 0; i < result->num_edges; i++) {
                    result->result_edges[i] = result_edges_vec[i];
                }
            }

            result->success = 1;
        } else {
            // Enhanced failure reporting
            snprintf(result->error_message, sizeof(result->error_message),
                    "PCST algorithm failed: root=%d, clusters=%d, pruning=%d, nodes=%d, edges=%d",
                    cpp_root, target_num_active_clusters, pruning_method, num_nodes, num_edges);
        }

    } catch (const std::exception& e) {
        snprintf(result->error_message, sizeof(result->error_message),
                "Exception: %s", e.what());
    } catch (...) {
        strcpy(result->error_message, "Unknown exception occurred");
    }

    return result;
}

void pcst_free_result(pcst_result_t* result) {
    if (result) {
        if (result->result_nodes) {
            free(result->result_nodes);
        }
        if (result->result_edges) {
            free(result->result_edges);
        }
        free(result);
    }
}

} // extern "C"