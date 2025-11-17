FROM postgis/postgis:18-3.6

# Install build dependencies for PostgreSQL extensions
RUN apt-get update && apt-get install -y \
    postgresql-server-dev-18 \
    build-essential \
    make \
    gcc \
    g++ \
    git \
    && rm -rf /var/lib/apt/lists/*

# Set work directory
WORKDIR /tmp/pg_pcst_fast

# Copy extension source code
COPY . .

# Build and install the extension
RUN make clean || true
RUN make
RUN make install

# Create initialization script to create the extension automatically
RUN echo "CREATE EXTENSION IF NOT EXISTS pcst_fast;" > /docker-entrypoint-initdb.d/01-create-pcst-extension.sql

# Set default environment variables
ENV POSTGRES_DB=testdb
ENV POSTGRES_USER=postgres
ENV POSTGRES_PASSWORD=postgres

# Expose PostgreSQL port
EXPOSE 5432

# Clean up build files but keep the extension installed
RUN cd / && rm -rf /tmp/pg_pcst_fast

# Add SQL script to be executed when the database starts
COPY test_data/z_connectors_for_test.sql /docker-entrypoint-initdb.d/

# Add a health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD pg_isready -U postgres -d testdb || exit 1