#!/usr/bin/env bash
# One player stands at spawn among 16, 256 and 4096 cows summoned on a square field around them,
# on flat terrain.
# Usage: scenarios/cows.sh [server]...
source "$(dirname "$0")/common.sh"
for cows in 16 256 4096; do
  measure --scenario=cows --terrain=flat --players=1 --cows="$cows"
done
