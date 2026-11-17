#!/usr/bin/env bash
# One player stands at spawn on flat terrain among cows summoned on a square spiral around them,
# adding cows while the server keeps up: about twice as many each step up to a thousand, then
# half again, up to 8192, all within render and simulation distance.
# Usage: scenarios/cows.sh [server]...
source "$(dirname "$0")/common.sh"
measure --scenario=cows --terrain=flat --cows=16,32,64,128,256,512,1024,1536,2048,3072,4096,6144,8192 "${ramp[@]}"
