#!/usr/bin/env bash
# Everyone places or breaks a block every tick at a spot of their own near spawn, on flat terrain
# so every spot stands on the same ground on every server, adding players while the server keeps
# up.
# Usage: scenarios/build.sh [server]...
source "$(dirname "$0")/common.sh"
measure --scenario=build --terrain=flat --players="$steps" "${ramp[@]}"
