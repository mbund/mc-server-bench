#!/usr/bin/env bash
# One player stands at spawn on flat terrain among cows summoned on a square spiral around them,
# adding cows while the server keeps up: a few, then 256 and doubling to 2048, where servers
# start to reach their limits, then half again, up to 8192, all within render and simulation
# distance.
# Usage: scenarios/cows.sh [server]...
source "$(dirname "$0")/common.sh"
measure --scenario=cows --terrain=flat --cows=16,256,512,1024,2048,3072,4096,6144,8192 "${ramp[@]}"
