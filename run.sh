#!/usr/bin/env bash
# The standard benchmark: every scenario in scenarios/ for the servers named or every one, then
# the report. Results gather in runs/standard/results.jsonl and the report in
# runs/standard/report.md. CI runs each scenario script in a job of its own, on a machine of its
# own, and joins their results into one report.
# Usage: ./run.sh [server]...
source "$(dirname "$0")/scenarios/common.sh"
for scenario in idle wander spread explore build cows warp; do
  MC_SERVER_BENCH_BUILT=1 "scenarios/$scenario.sh" "${servers[@]}"
done
./zig-out/bin/bench report "$out"
