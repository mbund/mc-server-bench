#!/usr/bin/env bash
# Everyone flies to a spot of their own, far enough apart that views never overlap, adding players
# while the server keeps up. The wide flat world reaches far enough for 256 players; on real
# terrain more than 24 would spread past the pregenerated square, so it stops there.
# Usage: scenarios/spread.sh [server]...
source "$(dirname "$0")/common.sh"
measure --scenario=spread --terrain=real --players=1,2,4,8,16,24 "${ramp[@]}"
measure --scenario=spread --terrain=wide --players="${steps%%,384*}" "${ramp[@]}"
