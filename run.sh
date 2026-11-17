#!/usr/bin/env bash
# The standard benchmark, for the servers named or every one: each scenario on flat terrain and
# idle, wander and spread on real terrain, with 1, 16 and 256 players, and one player among 16, 256
# and 4096 cows on flat terrain. Options for the sweep, like
# --scenarios=idle, replace its defaults. Results gather in runs/standard/results.jsonl and the
# report in runs/standard/report.md. CI runs one scenario per job, every server on that job's
# machine, with this same command, and joins their results into one report.
# Usage: ./run.sh [--scenarios=a,b] [vanilla|lightning-rod|pumpkin|steel|paper|paper-antixray-1|fabric|fabric-occlusion]...
set -euo pipefail
cd "$(dirname "$0")"
if [ -z "${MC_SERVER_BENCH_SHELL:-}" ]; then exec nix develop --command "$0" "$@"; fi
servers=()
options=()
for argument in "$@"; do
  if [[ $argument == --* ]]; then options+=("$argument"); else servers+=("$argument"); fi
done
[ ${#servers[@]} -ne 0 ] || servers=(vanilla lightning-rod pumpkin steel paper paper-antixray-1 fabric fabric-occlusion)
out=runs/standard
# CI builds every server in jobs of its own and hands this one the results.
[ -n "${MC_SERVER_BENCH_BUILT:-}" ] || ./setup.sh bench "${servers[@]}"
list=${servers[*]}
./zig-out/bin/bench sweep --servers="${list// /,}" --terrains=real,flat \
  --scenarios=idle,wander,spread,explore,build,cows --players=1,16,256 --cows=16,256,4096 --out="$out" "${options[@]}"
./zig-out/bin/bench report "$out"
