# pg_pcst_fast - PostgreSQL Prize Collecting Steiner Tree Extension

A PostgreSQL extension that implements the Prize Collecting Steiner Tree (PCST) Fast algorithm. This algorithm finds the optimal subset of nodes and edges in a graph that maximizes the difference between collected prizes and connection costs while maintaining connectivity.

This extension wraps the PCST Fast algorithm from [fraenkel-lab/pcst_fast](https://github.com/fraenkel-lab/pcst_fast) and provides a native PostgreSQL interface with array-based parameters, plus built-in visualization tools for result analysis.

## Features

- High-performance C++ implementation of the PCST Fast algorithm
- Native PostgreSQL integration with array-based interface
- Supports multiple pruning methods (none, simple, gw, strong)
- Configurable root nodes and clustering options
- **Built-in ASCII visualization** for result analysis and debugging
- **Cost-benefit analysis** with detailed edge and node breakdowns

## Installation

### Option 1: Docker (Recommended)

The easiest way to get started is using Docker with PostgreSQL + PostGIS:

```bash
# Clone the repository
git clone https://github.com/yourusername/pg_pcst_fast.git
cd pg_pcst_fast

# Build and run with Docker Compose
docker-compose up --build

# Database will be available at localhost:5432
# Database: testdb, User: postgres, Password: postgres
```

Connect to the database:
```bash
# Using psql
psql -h localhost -U postgres -d testdb

# Using any PostgreSQL client
# Host: localhost, Port: 5432, Database: testdb, User: postgres, Password: postgres
```

**Docker setup includes:**
- ✅ PostGIS 18 with spatial extensions
- ✅ PCST Fast extension built from source
- ✅ Extension automatically created and ready to use
- ✅ All visualization functions available immediately

### Option 2: Manual Installation

For production installations:

### Prerequisites

- PostgreSQL 12 or later with development headers
- C++ compiler with C++11 support (gcc, clang)
- GNU Make

### Build and Install

```bash
# Clone the repository
git clone https://github.com/yourusername/pg_pcst_fast.git
cd pg_pcst_fast

# Build and install the extension
make
sudo make install

# Connect to your database and create the extension
psql -d your_database -c "CREATE EXTENSION pcst_fast;"
```

## Usage

### Basic PCST Function

The extension provides the `pcst_fast()` function that takes the following parameters:

```sql
SELECT * FROM pcst_fast(
    edges integer[][],         -- Array of [source, target] pairs
    prizes float8[],           -- Array of node prizes
    costs float8[],            -- Array of edge costs
    root integer,              -- Root node (-1 for auto-select)
    num_clusters integer,      -- Target number of clusters
    pruning text,              -- Pruning method: 'none', 'simple', 'gw', 'strong'
    verbosity integer          -- Verbosity level (0-3)
);
```

### Example

```sql
-- Simple example with 4 nodes and 3 edges
SELECT * FROM pcst_fast(
    ARRAY[[0,1],[1,2],[2,3]],                    -- Edges: 0-1-2-3 chain
    ARRAY[50.0, 10.0, 15.0, 40.0]::float8[],    -- Node prizes
    ARRAY[5.0, 8.0, 12.0]::float8[],             -- Edge costs
    -1,                                           -- Auto-select root
    1,                                            -- Single cluster
    'strong',                                     -- Strong pruning
    0                                             -- Minimal output
);
```

Returns:
- `result_nodes`: Array of selected node indices
- `result_edges`: Array of selected edge indices

### Visualization Functions

The extension includes powerful visualization tools for analyzing PCST results:

#### Quick Visualization
```sql
-- Run PCST algorithm with built-in visualization
SELECT pcst_fast_with_viz(
    ARRAY[[0,1], [1,2], [2,3]],
    ARRAY[100.0, 50.0, 75.0, 120.0]::float8[],
    ARRAY[10.0, 15.0, 20.0]::float8[]
    -- Optional: root, clusters, pruning, verbosity (uses sensible defaults)
);
```

#### Detailed Analysis
```sql
-- First run the algorithm
WITH pcst_result AS (
    SELECT result_nodes, result_edges 
    FROM pcst_fast(
        ARRAY[[0,1], [1,2], [2,3]],
        ARRAY[100.0, 50.0, 75.0, 120.0]::float8[],
        ARRAY[10.0, 15.0, 20.0]::float8[],
        -1, 1, 'simple', 0
    )
)
-- Then visualize with full cost analysis
SELECT pcst_visualize_with_costs(
    ARRAY[[0,1], [1,2], [2,3]], 
    ARRAY[100.0, 50.0, 75.0, 120.0]::float8[],
    ARRAY[10.0, 15.0, 20.0]::float8[],
    result_nodes, 
    result_edges
) FROM pcst_result;
```

#### Visualization Output Features

The visualization provides:

- **Input Analysis**: Complete display of edges, prizes, and costs
- **Selection Results**: Which nodes and edges were chosen
- **Cost-Benefit Breakdown**: Total prizes vs. total costs with net benefit
- **Graph Structure**: Actual connectivity based on selected edges
- **Validation Warnings**: Detects inconsistencies in algorithm results
- **Summary Statistics**: Node/edge counts and optimization metrics

Example output:
```
PCST Algorithm Input & Results:
======================================

Input Edges:
Edge 0: [0,1] cost=10
Edge 1: [1,2] cost=15
Edge 2: [2,3] cost=20

Input Node Prizes:
Node 0: prize=100
Node 1: prize=50
Node 2: prize=75
Node 3: prize=120

Algorithm Results:
==================
Selected nodes: 0, 1, 2, 3
Selected edges: 0, 1, 2

Summary:
Total selected node prizes: 345
Total selected edge costs: 45
Net benefit (prizes - costs): 300

Actual connectivity pattern:
[0]———[1] (via edge 0)
[1]———[2] (via edge 1)
[2]———[3] (via edge 2)
```

### Advanced Usage

#### Pruning Method Comparison
```sql
-- Compare different pruning methods on the same graph
SELECT 'No Pruning' as method, pcst_fast_with_viz(edges, prizes, costs, -1, 1, 'none')
UNION ALL
SELECT 'Simple Pruning', pcst_fast_with_viz(edges, prizes, costs, -1, 1, 'simple')
UNION ALL  
SELECT 'Strong Pruning', pcst_fast_with_viz(edges, prizes, costs, -1, 1, 'strong');
```

#### Root Node Analysis
```sql
-- Test different root nodes (note: GW pruning may fail with specific roots)
SELECT 'Root=0' as test, pcst_fast_with_viz(edges, prizes, costs, 0, 1, 'simple')
UNION ALL
SELECT 'Root=1', pcst_fast_with_viz(edges, prizes, costs, 1, 1, 'simple')
UNION ALL
SELECT 'Auto Root', pcst_fast_with_viz(edges, prizes, costs, -1, 1, 'simple');
```

## Troubleshooting

### Known Issues

**Root Node with GW Pruning**: The combination of specific root nodes with 'gw' (Goemans-Williamson) pruning may cause algorithm failures. Use 'simple' or 'none' pruning when specifying root nodes.

```sql
-- ❌ May fail
SELECT pcst_fast_with_viz(edges, prizes, costs, 1, 1, 'gw');

-- ✅ Works reliably  
SELECT pcst_fast_with_viz(edges, prizes, costs, 1, 1, 'simple');
```

### Docker Troubleshooting

**Podman Users**: You may see a HEALTHCHECK warning - this can be safely ignored.

**Port Conflicts**: If port 5432 is in use, modify `docker-compose.yml`:
```yaml
ports:
  - "5433:5432"  # Use different host port
```

## Algorithm Details

The Prize Collecting Steiner Tree problem seeks to find a tree that connects a subset of nodes to maximize:
`Total Node Prizes - Total Edge Costs`

This implementation uses the fast approximation algorithm from the original [fraenkel-lab/pcst_fast](https://github.com/fraenkel-lab/pcst_fast) repository, which implements the algorithm described in:
- "A Fast Algorithm for the Prize Collecting Steiner Tree Problem" by Hegde et al.

### Pruning Methods

- **none**: No pruning (fastest, least optimal)
- **simple**: Basic pruning of unnecessary branches
- **gw**: Goemans-Williamson style pruning
- **strong**: Most aggressive pruning (slowest, most optimal)

## Attribution

This PostgreSQL extension is based on the PCST Fast algorithm implementation from:
- **Original Repository**: https://github.com/fraenkel-lab/pcst_fast
- **Original Authors**: Fraenkel Lab and contributors
- **Original License**: MIT License

The core algorithm implementation (pcst_fast.cc, pcst_fast.h, pairing_heap.h, priority_queue.h) is derived from the original repository. This PostgreSQL extension adds the PostgreSQL-specific wrapper layer (pcst_fast_pg.c, pcst_fast_c_wrapper.cpp) to enable database integration.

## License

MIT License - see LICENSE file for details.

This project maintains the same MIT license as the original pcst_fast implementation to ensure compatibility and proper attribution.

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.