#!/usr/bin/env bash
# Everyone flies to a spot of their own, far enough apart that views never overlap, with 1, 16 and
# 256 players on flat terrain. On real terrain more than one player would spread past the
# pregenerated square that is the same on every server, so it has one.
# Usage: scenarios/spread.sh [server]...
source "$(dirname "$0")/common.sh"
measure --scenario=spread --terrain=real --players=1
for players in 1 16 256; do
  measure --scenario=spread --terrain=flat --players="$players"
done
