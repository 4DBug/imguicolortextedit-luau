#!/usr/bin/env bash
# Runs every tests/t_*.luau against the core (tools/core submodule) in the Roblox mock.
cd "$(dirname "$0")/.."
fail=0
for t in tests/t_*.luau; do
    out=$(python3 tools/core/tools/test/run.py --module TextEditor=TextEditor.lua --main "$t" --quiet --roblox 2>&1)
    if echo "$out" | grep -q "^OK"; then echo "PASS $t"; else echo "FAIL $t"; echo "$out" | tail -20; fail=1; fi
done
exit $fail
