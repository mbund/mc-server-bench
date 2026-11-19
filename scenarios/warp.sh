#!/usr/bin/env bash
# No one online while each server runs 122,880 ticks back to back, as /tick sprint does, over 32
# force loaded chunks of sugar cane farm with 128 cows on it, which stop strolling with no player
# near, as vanilla's do, but still tick, fall and collide. Then a player joins to check every cane
# grew three tall. It measures how fast a server ticks with nothing to send. Paper keeps its
# animals active here, as it otherwise skips their movement with no player near. Folia, with no
# tick command, cannot.
# Usage: scenarios/warp.sh [server]...
source "$(dirname "$0")/common.sh"
measure --scenario=warp --terrain=flat
