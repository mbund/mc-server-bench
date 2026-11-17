#!/usr/bin/env bash
# Everyone flies back and forth across the pregenerated flat world without stopping, so servers
# load and send terrain from disk rather than generate it, adding players while the server keeps
# up.
# Usage: scenarios/explore.sh [server]...
source "$(dirname "$0")/common.sh"
measure --scenario=explore --terrain=flat --players="$steps" "${ramp[@]}"
