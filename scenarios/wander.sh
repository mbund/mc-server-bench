#!/usr/bin/env bash
# Everyone flies at walking speed at random near spawn, in sight of each other, on real and flat
# terrain, adding players while the server keeps up.
# Usage: scenarios/wander.sh [server]...
source "$(dirname "$0")/common.sh"
for terrain in real flat; do
  measure --scenario=wander --terrain="$terrain" --players="$steps" "${ramp[@]}"
done
