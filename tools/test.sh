#!/usr/bin/env bash
# Runs every tests/t_*.luau against the core (tools/core submodule) in the Roblox mock.
cd "$(dirname "$0")/.."
fail=0
for t in tests/t_*.luau; do
    out=$(python3 tools/core/tools/test/run.py --module TextEditor=TextEditor.lua --main "$t" --quiet --roblox 2>&1)
    if echo "$out" | grep -q "^OK"; then echo "PASS $t"; else echo "FAIL $t"; echo "$out" | tail -20; fail=1; fi
done
# example LocalScript: 400 frames of random input (mock drives Stepped, not RenderStepped)
ex=$(mktemp --suffix=.luau); sed 's/RenderStepped/Stepped/' examples/roblox/main.client.luau > "$ex"
out=$(python3 tools/core/tools/test/run.py --module TextEditor=TextEditor.lua --main "$ex" --roblox 2>&1); rm -f "$ex"
if echo "$out" | grep -q "^avg frame"; then echo "PASS examples/roblox/main.client.luau"; else echo "FAIL examples/roblox/main.client.luau"; echo "$out" | tail -20; fail=1; fi
exit $fail
