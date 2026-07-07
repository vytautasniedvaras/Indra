#!/usr/bin/env bash
# Run a build/test command, mirroring compiler/test errors as GitHub
# annotations (::error workflow commands). Raw job logs are served from blob
# storage that some dev environments can't reach; annotations come back
# through the api.github.com check-runs endpoint, which they can.
set -o pipefail
log="$(mktemp)"
"$@" 2>&1 | tee "$log"
status=$?
if [ $status -ne 0 ]; then
  # swiftc format: path:line:col: error: message
  grep -E '^[^ :]+:[0-9]+:[0-9]+: (error|warning): ' "$log" | grep ': error: ' | sort -u | head -45 \
    | sed -E 's|^([^:]+):([0-9]+):([0-9]+): error: (.*)|::error file=\1,line=\2::\4|'
  # XCTest failure lines
  grep -E ': error: .+ : ' "$log" | sort -u | head -20 \
    | sed -E 's|^(.*)$|::error ::\1|' | head -4
fi
exit $status
