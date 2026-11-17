#!/usr/bin/env bash
# Everyone stands still at spawn, on real and flat terrain, with 1, 16 and 256 players.
# Usage: scenarios/idle.sh [server]...
source "$(dirname "$0")/common.sh"
for terrain in real flat; do
  for players in 1 16 256; do
    measure --scenario=idle --terrain="$terrain" --players="$players"
  done
done
