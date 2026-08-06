#!/bin/sh
# M3+ acceptance: run trace_runner over the ruffle AVM1 corpus and diff
# against each dir's output.txt. pass_list.txt is a ratchet — entries may
# only be added, never removed. (trace_runner lands in M3.)
set -u
CORPUS="${CORPUS:-reference/ruffle/tests/tests/swfs/avm1}"
echo "run_avm1: trace_runner not built yet (M3)"; exit 1
