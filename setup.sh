#!/usr/bin/env bash
# Builds the servers named, or every one, at its pinned version, with the bench and the worlds
# they read. Steps already done are skipped. `terrain` builds only the worlds, which CI makes once
# and shares between its jobs, and `bench` only the bench.
# Usage: ./setup.sh [vanilla|lightning-rod|pumpkin|steel|paper|paper-antixray-1|terrain|bench]...
set -euo pipefail
cd "$(dirname "$0")"
# The flake's lock pins every toolchain, so builds happen inside its shell.
if [ -z "${MC_SERVER_BENCH_SHELL:-}" ]; then exec nix develop --command "$0" "$@"; fi
root=$PWD
build=$root/servers/build
mkdir -p "$build"
targets=" ${*:-vanilla lightning-rod pumpkin steel paper paper-antixray-1} "
wants() {
  for name in "$@"; do [[ $targets == *" $name "* ]] && return 0; done
  return 1
}

# The bench builds against Lightning Rod's protocol packages.
git submodule update --init servers/lightning-rod
zig build -Drelease

# Vanilla 26.2, checked against the hash Mojang publishes. It also generates the worlds.
jar=servers/vanilla/server.jar
sha=823e2250d24b3ddac457a60c92a6a941943fcd6a
if wants vanilla terrain lightning-rod pumpkin paper paper-antixray-1; then
  if ! echo "$sha  $jar" | sha1sum --check --status 2>/dev/null; then
    mkdir -p servers/vanilla
    curl -fsSL -o "$jar" "https://piston-data.mojang.com/v1/objects/$sha/server.jar"
    echo "$sha  $jar" | sha1sum --check
  fi
fi

# The real terrain world, which vanilla generates once from a fixed seed and every server but
# SteelMC reads. SteelMC reads no vanilla worlds and generates the same seed itself.
if wants terrain vanilla lightning-rod pumpkin paper paper-antixray-1 && [ ! -d "$build/terrain/vanilla/world" ]; then
  ./zig-out/bin/bench pregen --radius=64
fi

# Pumpkin reads flat layers only from vanilla's world generation settings, so vanilla makes them
# once from the same settings the bench gives it.
if wants terrain pumpkin && [ ! -f "$build/flat/world_gen_settings.dat" ]; then
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

# Lightning Rod, built from its packages by the bench as a server outside its repository would be,
# and the real terrain imported with its caches built, as vanilla saves its light with the chunks.
if wants lightning-rod; then
  zig build -Drelease lightning-rod -p "$build/lightning-rod"
  if [ ! -d "$build/terrain/lightning-rod" ]; then
    (cd servers/lightning-rod/tools/world-import && zig build -Doptimize=ReleaseSafe -p "$build/world-import")
    "$build/world-import/bin/world-import" --input "$build/terrain/vanilla/world" --output "$build/terrain/lightning-rod" --skip-unsupported --prewarm
  fi
fi

# Pumpkin, as its README builds it. Its generated data crate needs a deep stack to compile.
if wants pumpkin; then
  git submodule update --init --recursive servers/pumpkin
  (cd servers/pumpkin && RUST_MIN_STACK=1073741824 cargo build --release)
fi

# SteelMC, in its own dev shell, which pins the nightly toolchain it needs. Its build downloads
# vanilla assets, which the sandbox of its Nix package cannot.
if wants steel; then
  git submodule update --init --recursive servers/steel
  # Its console reads commands only from a terminal, and the bench pipes them for tick queries.
  patch=$root/patches/steel-console-stdin.patch
  git -C servers/steel apply --reverse --check "$patch" 2>/dev/null || git -C servers/steel apply "$patch"
  (cd servers/steel && nix develop "path:$PWD" --command cargo build --release -p steel)
fi

# Paper 26.2 build 135, checked against the hash its download service publishes. Its launcher
# patches the vanilla jar and fetches libraries once here, and every run links them.
if wants paper paper-antixray-1; then
  paper=servers/paper/paper.jar
  paper_sha=ef3dbc68b013deafdbbee3bebf1ba351671ebcda94a8f136809b7532d5ba2fe1
  if ! echo "$paper_sha  $paper" | sha256sum --check --status 2>/dev/null; then
    mkdir -p servers/paper
    curl -fsSL -o "$paper" "https://fill-data.papermc.io/v1/objects/$paper_sha/paper-26.2-135.jar"
    echo "$paper_sha  $paper" | sha256sum --check
  fi
  [ -d servers/paper/versions ] || (cd servers/paper && java -Dpaperclip.patchonly=true -jar paper.jar)
fi
