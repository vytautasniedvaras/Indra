#!/usr/bin/env bash
# Run a build/test command, capturing output for two feedback channels the
# headless dev environment CAN reach (raw job logs live on blob storage it
# cannot): GitHub ::error annotations, and /tmp/swift-ci.log which a later
# workflow step publishes to the ci-logs branch on failure.
set -o pipefail
log="${SWIFT_LOG:-/tmp/swift-ci.log}"
{ echo "=== $* ==="; "$@" 2>&1; } | tee -a "$log"
status=$?
if [ $status -ne 0 ]; then
  # swiftc format: path:line:col: error: message
  grep -E '^[^ ]+:[0-9]+(:[0-9]+)?: error: ' "$log" | sort -u | head -45 \
    | sed -E 's|^([^:]+):([0-9]+)(:[0-9]+)?: error: (.*)|::error file=\1,line=\2::\4|'
fi
exit $status
