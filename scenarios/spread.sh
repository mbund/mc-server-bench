#!/usr/bin/env bash
# Everyone flies to a spot of their own, far enough apart that views never overlap, adding players
# while the server keeps up. On real terrain each player has a copy of its own of a tile of
# vanilla's terrain, on a grid of copies with room for 512; the wide flat world reaches far enough
# for 256.
# Usage: scenarios/spread.sh [server]...
source "$(dirname "$0")/common.sh"
measure --scenario=spread --terrain=tiled --players="$steps" "${ramp[@]}"
measure --scenario=spread --terrain=wide --players="${steps%%,384*}" "${ramp[@]}"
