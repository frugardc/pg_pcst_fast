# pg_pcst_fast - PostgreSQL Prize Collecting Steiner Tree Extension

A PostgreSQL extension that implements the Prize Collecting Steiner Tree (PCST) Fast algorithm. This algorithm finds the optimal subset of nodes and edges in a graph that maximizes the difference between collected prizes and connection costs while maintaining connectivity.

This extension wraps the PCST Fast algorithm from [fraenkel-lab/pcst_fast](https://github.com/fraenkel-lab/pcst_fast) and provides a native PostgreSQL interface with a pg_routing-style SQL query interface, plus built-in visualization tools for result analysis.

## Features

- **pg_routing-style interface** - Use SQL queries to define your graph, just like pg_routing
- **Automatic ID mapping** - Works with your actual database IDs, no need to convert to 0-based indices
- High-performance C++ implementation of the PCST Fast algorithm
- Supports multiple pruning methods (none, simple, gw, strong)
- Configurable root nodes and clustering options
- **Built-in ASCII visualization** for result analysis and debugging
- **Cost-benefit analysis** with detailed edge and node breakdowns
- **Row-based results** - Returns one row per selected edge in pg_routing format

## Installation

### Option 1: Docker (For Testing/Getting Familiar)

Docker is provided for quick testing and getting familiar with the extension. **For production use, you should install the extension on your own PostgreSQL server.**

```bash
# Clone the repository
git clone https://github.com/frugardc/pg_pcst_fast.git
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

**Note:** The Docker setup is intended for testing and familiarization. For production deployments, install the extension on your own PostgreSQL server (see Option 2 below).

### Option 2: Manual Installation (Recommended for Production)

For production installations on your own PostgreSQL server:

#### Prerequisites

- PostgreSQL 12 or later with development headers (`postgresql-server-dev-*` on Debian/Ubuntu, `postgresql-devel` on RHEL/CentOS)
- C++ compiler with C++11 support (gcc, clang)
- GNU Make

#### Build and Install

```bash
# Clone the repository
git clone https://github.com/frugardc/pg_pcst_fast.git
cd pg_pcst_fast

# Build the extension
make

# Install the extension (requires sudo/root)
sudo make install

# Connect to your database and create the extension
psql -d your_database -c "CREATE EXTENSION pcst_fast;"
```

**Installation locations:**
- Extension SQL file: `$SHAREDIR/extension/pcst_fast--1.0.0.sql`
- Shared library: `$LIBDIR/pcst_fast.so`
- Control file: `$SHAREDIR/extension/pcst_fast.control`

To find these directories on your system:
```sql
SHOW sharedir;
SHOW dynamic_library_path;
```

#### Verifying Installation

```sql
-- Check that the extension is installed
SELECT * FROM pg_extension WHERE extname = 'pcst_fast';

-- List available functions
\df pgr_pcst*
\df pcst_fast*
```

## Usage

### Primary Function: `pgr_pcst_fast` (pg_routing-style)

The main function `pgr_pcst_fast()` uses a pg_routing-style interface where you provide SQL queries for edges and nodes. This is the recommended way to use the extension as it works directly with your database tables and handles ID mapping automatically.

#### Function Signature

```sql
SELECT * FROM pgr_pcst_fast(
    edges_sql text,             -- SQL query returning: id, source, target, cost
    nodes_sql text,              -- SQL query returning: id, prize
    root_id integer DEFAULT -1,  -- Root node ID (or -1 for auto-select)
    num_clusters integer DEFAULT 1,  -- Number of clusters
    pruning text DEFAULT 'simple',   -- Pruning method: 'none', 'simple', 'gw', 'strong'
    verbosity integer DEFAULT 0      -- Verbosity level (0-3)
);
```

#### Return Format

Returns one row per selected edge in pg_routing format:
- `seq` - Sequence number (1-based)
- `edge` - Edge ID (bigint)
- `source` - Source node ID (bigint)
- `target` - Target node ID (bigint)
- `cost` - Edge cost (float8)

#### Basic Example

```sql
-- Create sample tables
CREATE TABLE edges (
    id integer PRIMARY KEY,
    source integer NOT NULL,
    target integer NOT NULL,
    cost float8 NOT NULL
);

CREATE TABLE nodes (
    id integer PRIMARY KEY,
    prize float8 NOT NULL
);

-- Insert sample data
INSERT INTO edges (id, source, target, cost) VALUES
    (1, 100, 101, 5.0),
    (2, 101, 102, 8.0),
    (3, 102, 103, 12.0),
    (4, 100, 102, 20.0);

INSERT INTO nodes (id, prize) VALUES
    (100, 50.0),
    (101, 10.0),
    (102, 15.0),
    (103, 40.0);

-- Run PCST algorithm
SELECT * FROM pgr_pcst_fast(
    'SELECT id, source, target, cost FROM edges',
    'SELECT id, prize FROM nodes',
    -1,      -- Auto-select root
    1,       -- Single cluster
    'simple', -- Pruning method
    0        -- Verbosity
);
```

**Result:**
```
 seq | edge | source | target | cost
-----+------+--------+--------+------
   1 |    1 |    100 |    101 |  5.0
   2 |    2 |    101 |    102 |  8.0
   3 |    3 |    102 |    103 | 12.0
```

#### Real-World Example with Filtering

```sql
-- Use PCST on a subset of your network
SELECT * FROM pgr_pcst_fast(
    'SELECT id, source, target, cost
     FROM road_network
     WHERE region_id = 5
     ORDER BY id',
    'SELECT id, prize
     FROM important_locations
     WHERE region_id = 5',
    -1, 1, 'strong', 0
);
```

#### Node Prize Defaults

**Important:** Nodes that appear in edges but are not in the nodes query will automatically have prize = 0.0. These nodes can still be selected as "Steiner nodes" if they help connect nodes with positive prizes, but they don't contribute to the objective function.

```sql
-- If node 105 appears in edges but not in nodes query:
-- It will have prize = 0.0 and can be selected for connectivity
SELECT * FROM pgr_pcst_fast(
    'SELECT id, source, target, cost FROM edges',  -- Contains node 105
    'SELECT id, prize FROM nodes',                  -- Does NOT contain node 105
    -1, 1, 'simple', 0
);
-- Node 105 will have prize = 0.0
```

### Visualization Function

For debugging and understanding results, use `pgr_pcst_fast_with_viz()`:

```sql
SELECT pgr_pcst_fast_with_viz(
    'SELECT id, source, target, cost FROM edges',
    'SELECT id, prize FROM nodes',
    -1,      -- Auto-select root
    1,       -- Single cluster
    'simple', -- Pruning method
    0        -- Verbosity
);
```

This returns a detailed text visualization showing:
- All input edges and costs
- All input node prizes
- Selected nodes and edges
- Cost-benefit analysis
- Graph connectivity structure

### Lower-Level Function: `pcst_fast` (Array-based)

For advanced users or programmatic use, the extension also provides `pcst_fast()` which takes arrays directly. This is a lower-level function that requires you to manage ID-to-index mapping yourself.

```sql
SELECT * FROM pcst_fast(
    edges integer[][],         -- Array of [source, target] pairs (0-based indices)
    prizes float8[],           -- Array of node prizes (indexed by node index)
    costs float8[],            -- Array of edge costs (indexed by edge index)
    root integer,              -- Root node index (-1 for auto-select)
    num_clusters integer,      -- Target number of clusters
    pruning text,              -- Pruning method: 'none', 'simple', 'gw', 'strong'
    verbosity integer          -- Verbosity level (0-3)
);
```

**Note:** This function uses 0-based indices, so you need to convert your database IDs to consecutive indices (0, 1, 2, ...) before calling it. Most users should use `pgr_pcst_fast()` instead.

### Advanced Usage

#### Pruning Method Comparison

```sql
-- Compare different pruning methods
SELECT 'No Pruning' as method, COUNT(*) as edges_selected
FROM pgr_pcst_fast(edges_sql, nodes_sql, -1, 1, 'none', 0)
UNION ALL
SELECT 'Simple Pruning', COUNT(*)
FROM pgr_pcst_fast(edges_sql, nodes_sql, -1, 1, 'simple', 0)
UNION ALL
SELECT 'Strong Pruning', COUNT(*)
FROM pgr_pcst_fast(edges_sql, nodes_sql, -1, 1, 'strong', 0);
```

#### Root Node Analysis

```sql
-- Test different root nodes
SELECT 'Root=100' as test, COUNT(*) as edges_selected
FROM pgr_pcst_fast(edges_sql, nodes_sql, 100, 1, 'simple', 0)
UNION ALL
SELECT 'Auto Root', COUNT(*)
FROM pgr_pcst_fast(edges_sql, nodes_sql, -1, 1, 'simple', 0);
```

#### Joining Results with Original Data

```sql
-- Get full edge details for selected edges
SELECT e.*, r.seq, r.cost as selected_cost
FROM pgr_pcst_fast(
    'SELECT id, source, target, cost FROM edges',
    'SELECT id, prize FROM nodes',
    -1, 1, 'simple', 0
) r
JOIN edges e ON e.id = r.edge
ORDER BY r.seq;
```

#### Multiple Clusters

```sql
-- Allow the algorithm to create multiple disconnected clusters
SELECT * FROM pgr_pcst_fast(
    'SELECT id, source, target, cost FROM edges',
    'SELECT id, prize FROM nodes',
    -1,      -- Auto-select root
    3,       -- Allow up to 3 clusters
    'simple',
    0
);
```

## Algorithm Details

The Prize Collecting Steiner Tree problem seeks to find a tree (or forest) that connects a subset of nodes to maximize:
```
Total Node Prizes - Total Edge Costs
```

This implementation uses the fast approximation algorithm from the original [fraenkel-lab/pcst_fast](https://github.com/fraenkel-lab/pcst_fast) repository, which implements the algorithm described in:
- "A Fast Algorithm for the Prize Collecting Steiner Tree Problem" by Hegde et al.

### Pruning Methods

- **none**: No pruning (fastest, least optimal)
- **simple**: Basic pruning of unnecessary branches (recommended default)
- **gw**: Goemans-Williamson style pruning
- **strong**: Most aggressive pruning (slowest, most optimal)

### Performance

The extension uses efficient C++ implementations with:
- Hash table-based ID mapping for O(1) lookups
- Optimized memory management
- Scales to millions of nodes and edges

## Troubleshooting

### Known Issues

**Root Node with GW Pruning**: The combination of specific root nodes with 'gw' (Goemans-Williamson) pruning may cause algorithm failures. Use 'simple' or 'none' pruning when specifying root nodes.

```sql
-- ❌ May fail
SELECT * FROM pgr_pcst_fast(edges_sql, nodes_sql, 100, 1, 'gw', 0);

-- ✅ Works reliably
SELECT * FROM pgr_pcst_fast(edges_sql, nodes_sql, 100, 1, 'simple', 0);
```

### Docker Troubleshooting

**Podman Users**: You may see a HEALTHCHECK warning - this can be safely ignored.

**Port Conflicts**: If port 5432 is in use, modify `docker-compose.yml`:
```yaml
ports:
  - "5433:5432"  # Use different host port
```

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

