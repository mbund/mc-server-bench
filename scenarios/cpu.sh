#!/usr/bin/env bash
# Checks this machine has every feature MC_SERVER_BENCH_CPU names past its model, like the aes and
# vaes of x86_64_v3+aes+vaes, which CI builds for on one machine and runs on others. Binaries built
# for a feature the machine lacks stop at the first instruction of it, which this says plainly
# instead. A plain model, or none, checks nothing.
set -euo pipefail
target=${MC_SERVER_BENCH_CPU:-native}
[[ $target == *+* ]] || exit 0
flags=" $(grep -m1 '^flags' /proc/cpuinfo | cut -d: -f2) "
missing=()
IFS=+ read -r -a features <<< "${target#*+}"
for feature in "${features[@]}"; do
  [[ $flags == *" $feature "* ]] || missing+=("$feature")
done
if [ ${#missing[@]} -ne 0 ]; then
  echo "this machine's CPU, $(grep -m1 '^model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//'), lacks ${missing[*]}, which MC_SERVER_BENCH_CPU=$target builds for" >&2
  exit 1
fi
