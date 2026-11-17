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
# CI builds every server in jobs of its own and hands the scenario jobs the results.
[ -n "${MC_SERVER_BENCH_BUILT:-}" ] || ./setup.sh bench "${servers[@]}"

# Measures every server in turn with the same harness options, past any run that fails.
measure() {
  for server in "${servers[@]}"; do
    ./zig-out/bin/bench run --server="$server" --out="$out" "$@" || echo "$server failed: $*" >&2
  done
}
