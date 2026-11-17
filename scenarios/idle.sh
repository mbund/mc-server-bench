#!/usr/bin/env bash
# Everyone stands still at spawn, on real and flat terrain, adding players while the server keeps
# up.
# Usage: scenarios/idle.sh [server]...
source "$(dirname "$0")/common.sh"
for terrain in real flat; do
  measure --scenario=idle --terrain="$terrain" --players="$steps" "${ramp[@]}"
done
