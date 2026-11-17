#!/usr/bin/env bash
# Everyone places or breaks a block every tick at a spot of their own near spawn, with 1, 16 and
# 256 players, on flat terrain, so every spot stands on the same ground on every server.
# Usage: scenarios/build.sh [server]...
source "$(dirname "$0")/common.sh"
for players in 1 16 256; do
  measure --scenario=build --terrain=flat --players="$players"
done
