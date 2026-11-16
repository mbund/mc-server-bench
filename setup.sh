#!/usr/bin/env bash
# Builds every server at its pinned version, and the bench itself. Run inside `nix develop`,
# whose lock pins the toolchains. Steps that are already done are skipped.
set -euo pipefail
cd "$(dirname "$0")"
root=$PWD
build=$root/servers/build
mkdir -p "$build"

git submodule update --init --recursive

# Vanilla 26.2, checked against the hash Mojang publishes.
jar=servers/vanilla/server.jar
sha=823e2250d24b3ddac457a60c92a6a941943fcd6a
if ! echo "$sha  $jar" | sha1sum --check --status 2>/dev/null; then
  mkdir -p servers/vanilla
  curl -fsSL -o "$jar" "https://piston-data.mojang.com/v1/objects/$sha/server.jar"
  echo "$sha  $jar" | sha1sum --check
fi

# Lightning Rod, built as its benchmarks are.
(cd servers/lightning-rod/examples/vanilla && zig build -Doptimize=ReleaseSafe -p "$build/lightning-rod")

# Pumpkin, as its README builds it. Its generated data crate needs a deep stack to compile.
(cd servers/pumpkin && RUST_MIN_STACK=1073741824 cargo build --release)

# SteelMC, in its own dev shell, which pins the nightly toolchain it needs. Its build downloads
# vanilla assets, which the sandbox of its Nix package cannot.
(cd servers/steel && nix develop "path:$PWD" --command cargo build --release -p steel)

# Pumpkin reads flat layers only from vanilla's world generation settings, so vanilla makes them
# once from the same settings the bench gives it.
if [ ! -f "$build/flat/world_gen_settings.dat" ]; then
  scratch=$(mktemp -d)
  echo "eula=true" > "$scratch/eula.txt"
  cat > "$scratch/server.properties" <<'EOF'
online-mode=false
server-port=25799
level-type=minecraft\:flat
generator-settings={"layers"\:[{"block"\:"minecraft\:stone","height"\:128},{"block"\:"minecraft\:grass_block","height"\:1}],"biome"\:"minecraft\:plains","structure_overrides"\:[]}
generate-structures=false
EOF
  mkfifo "$scratch/console"
  (cd "$scratch" && exec java -DbundlerRepoDir="$root/servers/vanilla/bundle" -jar "$root/$jar" --nogui < console > server.log) &
  server=$!
  exec 3> "$scratch/console"
  # Commands sent before the world is ready fail, so stop waits for it.
  until grep -q "Done (" "$scratch/server.log" 2>/dev/null; do sleep 1; done
  echo stop >&3
  exec 3>&-
  wait "$server"
  mkdir -p "$build/flat"
  cp "$scratch/world/data/minecraft/world_gen_settings.dat" "$build/flat/"
  rm -rf "$scratch"
fi

zig build -Doptimize=ReleaseSafe
