# What every scenario script and run.sh share, sourced by them: the flake's shell unless already
# in it or where it is not needed, the servers named or every one, built unless CI built them
# already, and `measure`, which runs each of those servers with the same harness options.
# --terrain=<terrain> runs only the runs on that terrain, as CI runs each terrain of a scenario on
# a machine of its own. --encryption=off runs every server without encrypting its sessions, to
# measure the rest of it.
set -euo pipefail
script=$(realpath "$0")
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [ -z "${MC_SERVER_BENCH_SHELL:-}" ]; then exec nix develop --command "$script" "$@"; fi
servers=()
only=
encryption=on
for argument in "$@"; do
  case $argument in
    --terrain=*) only=${argument#--terrain=} ;;
    --encryption=*) encryption=${argument#--encryption=} ;;
    *) servers+=("$argument") ;;
  esac
done
[ ${#servers[@]} -ne 0 ] || servers=(vanilla lightning-rod pumpkin steel paper paper-antifreecam folia fabric-optimized)
out=runs/standard
# The worlds runs start from, Lightning Rod's and SteelMC's own when they run. CI builds every
# server and world in jobs of its own and hands the scenario jobs the results.
worlds=(terrain-real terrain-flat terrain-wide)
if [[ " ${servers[*]} " == *" lightning-rod "* ]]; then worlds+=(import-real import-flat import-wide); fi
if [[ " ${servers[*]} " == *" steel "* ]]; then worlds+=(steel-real steel-flat steel-wide); fi
[ -n "${MC_SERVER_BENCH_BUILT:-}" ] || ./setup.sh bench "${worlds[@]}" "${servers[@]}"

# Measures every server in turn with the same harness options, past any run that fails, unless
# the run is on another terrain than the one asked for.
measure() {
  for argument in "$@"; do
    if [[ -n $only && $argument == --terrain=* && $argument != "--terrain=$only" ]]; then return; fi
  done
  for server in "${servers[@]}"; do
    ./zig-out/bin/bench run --server="$server" --out="$out" --encryption="$encryption" "$@" || echo "$server failed: $*" >&2
  done
}

# The players a ramp adds step by step while the server keeps up, each step settling 10 seconds
# and measured for 20. One player is the baseline; the steps double while every server keeps up,
# and grow about half again each time from 128, where servers start to reach their limits.
steps=1,16,32,64,128,192,256,384,512
ramp=(--warmup=10 --seconds=20)
