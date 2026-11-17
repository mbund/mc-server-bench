#!/usr/bin/env bash
# Everyone flies at walking speed at random near spawn, in sight of each other, on real and flat
# terrain, with 1, 16 and 256 players.
# Usage: scenarios/wander.sh [server]...
source "$(dirname "$0")/common.sh"
for terrain in real flat; do
  for players in 1 16 256; do
    measure --scenario=wander --terrain="$terrain" --players="$players"
  done
done
