#!/usr/bin/env bash
# The standard benchmark, for the servers named or every one: each scenario on flat terrain and
# idle, wander and spread on real terrain, with 1, 5 and 10 players. Results gather in
# runs/standard/results.jsonl and the report in runs/standard/report.md. CI runs one server per
# job with this same command and joins their results into one report.
# Usage: ./run.sh [vanilla|lightning-rod|pumpkin|steel|paper|paper-antixray-1|fabric|fabric-occlusion]...
set -euo pipefail
cd "$(dirname "$0")"
if [ -z "${MC_SERVER_BENCH_SHELL:-}" ]; then exec nix develop --command "$0" "$@"; fi
servers=${*:-vanilla lightning-rod pumpkin steel paper paper-antixray-1 fabric fabric-occlusion}
out=runs/standard
./setup.sh $servers
./zig-out/bin/bench sweep --servers="${servers// /,}" --terrains=real,flat \
  --scenarios=idle,wander,spread,explore,build --players=1,5,10 --out="$out"
./zig-out/bin/bench report "$out"
