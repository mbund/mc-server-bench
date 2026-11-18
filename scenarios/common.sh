# What every scenario script and run.sh share, sourced by them: the flake's shell unless already
# in it or where it is not needed, the servers named or every one, built unless CI built them
# already, and `measure`, which runs each of those servers with the same harness options.
set -euo pipefail
script=$(realpath "$0")
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [ -z "${MC_SERVER_BENCH_SHELL:-}" ]; then exec nix develop --command "$script" "$@"; fi
if [ $# -ne 0 ]; then
  servers=("$@")
else
  servers=(vanilla lightning-rod pumpkin steel paper paper-antixray-1 fabric fabric-occlusion)
fi
out=runs/standard
# The worlds runs start from, and SteelMC's own when it runs. CI builds every server and world in
# jobs of their own and hands the scenario jobs the results.
worlds=(terrain terrain-wide)
if [[ " ${servers[*]} " == *" lightning-rod "* ]]; then worlds+=(import import-wide); fi
if [[ " ${servers[*]} " == *" steel "* ]]; then worlds+=(terrain-steel terrain-steel-wide); fi
[ -n "${MC_SERVER_BENCH_BUILT:-}" ] || ./setup.sh bench "${worlds[@]}" "${servers[@]}"

# Measures every server in turn with the same harness options, past any run that fails.
measure() {
  for server in "${servers[@]}"; do
    ./zig-out/bin/bench run --server="$server" --out="$out" "$@" || echo "$server failed: $*" >&2
  done
}

# The players a ramp adds step by step, about half again each time, while the server keeps up,
# each step settling 10 seconds and measured for 20.
steps=1,2,4,8,16,24,32,48,64,96,128,192,256,384,512
ramp=(--warmup=10 --seconds=20)
