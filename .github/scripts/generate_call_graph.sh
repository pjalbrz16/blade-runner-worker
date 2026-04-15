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

from Call call, Callable caller, Callable callee
where
  call.getEnclosingCallable() = caller
  and call.getCallee() = callee
  and callee.fromSource()
select
  call.getFile().getRelativePath() as caller_path,
  caller.getDeclaringType().getQualifiedName() + "." + caller.getName() as caller_name,
  call.getLocation().getStartLine() as call_line,
  callee.getFile().getRelativePath() as callee_path,
  callee.getDeclaringType().getQualifiedName() + "." + callee.getName() as callee_name,
  callee.getLocation().getStartLine() as callee_line
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
import re

changed_lines = {}
impacted_files = []

if os.path.exists('pr_diff.txt'):
    current_file = None
    with open('pr_diff.txt', 'r') as f:
        for line in f:
            # Detect file paths in the diff
            if line.startswith('+++ b/'):
                current_file = line[6:].strip()
                changed_lines[current_file] = set()
            # Detect line number chunks (e.g., @@ -1050,7 +1053,6 @@)
            elif line.startswith('@@') and current_file:
                # Extract the added/modified line numbers (+start,count)
                match = re.search(r'\+([0-9]+)(?:,([0-9]+))?', line)
                if match:
                    start_line = int(match.group(1))
                    count = int(match.group(2)) if match.group(2) else 1
                    for i in range(start_line, start_line + count):
                        changed_lines[current_file].add(i)

    print(f'Loaded line-level diff for {len(changed_lines)} files.')

with open('full_call_graph.csv', 'r') as f_in, open('call_graph.csv', 'w', newline='') as f_out:
    reader = csv.reader(f_in)
    writer = csv.writer(f_out)
    next(reader, None) # Skip CodeQL header

    writer.writerow(['Caller', 'Callee'])

    match_count = 0

    for row in reader:
        # We now expect 6 columns from the new CodeQL query
        if len(row) == 6:
            c_path = row[0].strip()
            caller = row[1].strip()
            c_line = int(row[2].strip())

            cal_path = row[3].strip()
            callee = row[4].strip()
            cal_line = int(row[5].strip())

            is_impacted = False

            # Check if the exact line of the method call, or the exact line
            # of the method definition, was modified in the PR.
            for diff_path, lines in changed_lines.items():
                if c_path.endswith(diff_path) and c_line in lines:
                    is_impacted = True
                    break
                if cal_path.endswith(diff_path) and cal_line in lines:
                    is_impacted = True
                    break

            if is_impacted:
                writer.writerow([caller, callee])
                match_count += 1

print(f'Line filtering complete. Wrote {match_count} precise dependencies to call_graph.csv.')

"

echo "Call graph CSV successfully generated! Preview:"
head -n 5 call_graph.csv
