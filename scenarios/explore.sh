#!/usr/bin/env bash
# Everyone flies back and forth across the pregenerated flat world without stopping, with 1, 16
# and 256 players, so servers load and send terrain from disk rather than generate it.
# Usage: scenarios/explore.sh [server]...
source "$(dirname "$0")/common.sh"
for players in 1 16 256; do
  measure --scenario=explore --terrain=flat --players="$players"
done
