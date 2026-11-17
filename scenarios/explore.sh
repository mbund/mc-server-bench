#!/usr/bin/env bash
# Everyone flies outward into terrain never generated before, with 1, 16 and 256 players, on flat
# terrain, which every server generates alike.
# Usage: scenarios/explore.sh [server]...
source "$(dirname "$0")/common.sh"
for players in 1 16 256; do
  measure --scenario=explore --terrain=flat --players="$players"
done
