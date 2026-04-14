#!/bin/bash
set -e

echo "Create custom CodeQL query pack"
mkdir -p custom-query-pack
cd custom-query-pack

cat << 'EOF' > qlpack.yml
name: local/custom-queries
version: 1.0.0
dependencies:
  codeql/java-all: "*"
EOF

cat << 'EOF' > call_graph.ql
/**
 * @name PR Call Graph
 * @kind table
 * @id java/pr-call-graph
 */
import java

from Callable caller, Callable callee
where caller.polyCalls(callee)
  and callee.fromSource()
select
  caller.getFile().getRelativePath() as caller_path,
  caller.getDeclaringType().getQualifiedName() + "." + caller.getName() as caller_name,
  callee.getFile().getRelativePath() as callee_path,
  callee.getDeclaringType().getQualifiedName() + "." + callee.getName() as callee_name
EOF

echo "Installing CodeQL dependencies"
"$CODEQL_CLI" pack install

# Use the DB_PATH passed in from the GitHub Actions environment
echo "Running query against database at: $CODEQL_DB_PATH"
"$CODEQL_CLI" query run --database=$CODEQL_DB_PATH --output=../results.bqrs call_graph.ql

cd ..

echo "Decoding results to CSV"
"$CODEQL_CLI" bqrs decode results.bqrs --format=csv --output=full_call_graph.csv


echo "Filtering call graph to include only impacted files"
# Inline Python script to parse the CSV and filter the results
python3 -c "
import csv
import os

impacted_files = set()
# Read the impacted_files.csv generated in the pipeline
if os.path.exists('impacted_files.csv'):
    with open('impacted_files.csv', 'r') as f:
        reader = csv.reader(f)
        next(reader, None) # skip header
        for row in reader:
            if len(row) > 1:
                # Add the file path to our set
                impacted_files.add(row[1])

# Filter the CodeQL output
with open('full_call_graph.csv', 'r') as f_in, open('call_graph.csv', 'w') as f_out:
    reader = csv.reader(f_in)
    writer = csv.writer(f_out)
    next(reader, None) # skip CodeQL header

    # Write final header
    writer.writerow(['Caller', 'Callee'])

    # If the caller OR the callee is in the impacted files list, keep the dependency
    for row in reader:
        if len(row) == 4:
            caller_path, caller, callee_path, callee = row
            if caller_path in impacted_files or callee_path in impacted_files:
                writer.writerow([caller, callee])
"

echo "Call graph CSV successfully generated! Preview:"
head -n 5 call_graph.csv