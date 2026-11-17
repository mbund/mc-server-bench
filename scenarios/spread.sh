#!/usr/bin/env bash
# Everyone flies to a spot of their own, far enough apart that views never overlap. The wide flat
# world reaches far enough for 256 players; on real terrain more than one player would spread past
# the pregenerated square, so it has one.
# Usage: scenarios/spread.sh [server]...
source "$(dirname "$0")/common.sh"
measure --scenario=spread --terrain=real --players=1
for players in 1 16 256; do
  measure --scenario=spread --terrain=wide --players="$players"
done
