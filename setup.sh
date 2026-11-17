#!/usr/bin/env bash
# Builds the servers named, or every one, at its pinned version, with the bench and the worlds
# they read. Steps already done are skipped. `terrain` builds only the worlds, which CI makes once
# and shares between its jobs, and `bench` only the bench.
# Usage: ./setup.sh [vanilla|lightning-rod|pumpkin|steel|paper|paper-antixray-1|fabric|terrain|bench]...
set -euo pipefail
cd "$(dirname "$0")"
# The flake's lock pins every toolchain, so builds happen inside its shell.
if [ -z "${MC_SERVER_BENCH_SHELL:-}" ]; then exec nix develop --command "$0" "$@"; fi
root=$PWD
build=$root/servers/build
mkdir -p "$build"
targets=" ${*:-vanilla lightning-rod pumpkin steel paper paper-antixray-1 fabric} "
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
if wants vanilla terrain lightning-rod pumpkin paper paper-antixray-1 fabric; then
  if ! echo "$sha  $jar" | sha1sum --check --status 2>/dev/null; then
    mkdir -p servers/vanilla
    curl -fsSL -o "$jar" "https://piston-data.mojang.com/v1/objects/$sha/server.jar"
    echo "$sha  $jar" | sha1sum --check
  fi
fi

# The real terrain world, which vanilla generates once from a fixed seed and every server but
# SteelMC reads. SteelMC reads no vanilla worlds and generates the same seed itself.
if wants terrain vanilla lightning-rod pumpkin paper paper-antixray-1 fabric && [ ! -d "$build/terrain/vanilla/world" ]; then
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

# Fabric Loader 0.20.1 from its installer, checked against the hash Fabric's Maven publishes, and
# the mods pinned to their Modrinth releases for 26.2 and checked against Modrinth's hashes.
if wants fabric; then
  mkdir -p servers/fabric/mods
  installer=servers/fabric/fabric-installer-1.1.2.jar
  if ! echo "74685b5a0178c4dabd4be741a276d35c59b5ec96  $installer" | sha1sum --check --status 2>/dev/null; then
    curl -fsSL -o "$installer" https://maven.fabricmc.net/net/fabricmc/fabric-installer/1.1.2/fabric-installer-1.1.2.jar
    echo "74685b5a0178c4dabd4be741a276d35c59b5ec96  $installer" | sha1sum --check
  fi
  [ -f servers/fabric/fabric-server-launch.jar ] || java -jar "$installer" server -mcversion 26.2 -loader 0.20.1 -dir servers/fabric
  while read -r file url sha; do
    if ! echo "$sha  servers/fabric/mods/$file" | sha512sum --check --status 2>/dev/null; then
      curl -fsSL -o "servers/fabric/mods/$file" "$url"
      echo "$sha  servers/fabric/mods/$file" | sha512sum --check
    fi
  done <<'EOF'
ferritecore-9.0.0-fabric.jar https://cdn.modrinth.com/data/uXXizFIs/versions/d5ddUdiB/ferritecore-9.0.0-fabric.jar d81fa97e11784c19d42f89c2f433831d007603dd7193cee45fa177e4a6a9c52b384b198586e04a0f7f63cd996fed713322578bde9a8db57e1188854ae5cbe584
lithium-fabric-0.25.3+mc26.2.jar https://cdn.modrinth.com/data/gvQqBUqZ/versions/f7vZ0VWU/lithium-fabric-0.25.3%2Bmc26.2.jar 148b638f3c6229fbaf487120a2344a0af5e411a5aa6533d5db9d75da0a8c0d8304f63eb4cca13f4d03b2c9b4c23d559dd74c1d832422ef8a3087bd005e62a8bd
ScalableLux-fabric-0.3.0-alpha.0.3-all.jar https://cdn.modrinth.com/data/Ps1zyz6x/versions/EKLUURiy/ScalableLux-fabric-0.3.0-alpha.0.3-all.jar ea1551c8728a726f6ee82fed3040af52791943ef99f6b63428ed770797f60677e0160975ad59ad0f51bcd4a4ec2b5da39c6913ab2379f2e25d2397132d469a94
krypton-0.3.1.jar https://cdn.modrinth.com/data/fQEb0iXm/versions/5WeL0Nkz/krypton-0.3.1.jar b8d9af34cd0050493afb8a6232cb8f785daa9d8887b7045f6e6a53c6bb9b5ffc4318fd9b0347a940eacfeba4773f10cb80ae0be1e79ce4c1888f96eda21e564e
EOF
fi
