#!/usr/bin/env bash
# Builds the servers named, or every one, at its pinned version, with the bench and the worlds
# they read. Steps already done are skipped. `bench` builds only the bench, and the targets named
# after a terrain only that world for one server family, which CI makes once in jobs of their own
# and shares with the rest.
# Usage: ./setup.sh [vanilla|lightning-rod|pumpkin|steel|paper|paper-antifreecam|folia|fabric-optimized|bench
#                   |terrain-<terrain>|import-<terrain>|steel-<terrain>]..., with terrains real, flat, wide and tiled
set -euo pipefail
cd "$(dirname "$0")"
# The flake's lock pins every toolchain, so local builds happen inside its shell. CI installs the
# same versions itself, which is faster than Nix there, and sets MC_SERVER_BENCH_SHELL.
if [ -z "${MC_SERVER_BENCH_SHELL:-}" ]; then exec nix develop --command "$0" "$@"; fi
root=$PWD
build=$root/servers/build
mkdir -p "$build/versions"
targets=" ${*:-bench vanilla lightning-rod pumpkin steel paper paper-antifreecam folia fabric-optimized terrain-real terrain-flat terrain-wide terrain-tiled import-real import-flat import-wide import-tiled steel-real steel-flat steel-wide steel-tiled} "
wants() {
  for name in "$@"; do [[ $targets == *" $name "* ]] && return 0; done
  return 1
}
# The commit a server was built from, which its results name.
record() {
  git -C "servers/$1" rev-parse --short=12 HEAD > "$build/versions/$1"
}

# Every server built from source targets the same CPU model: this machine's unless told one, as
# CI does, which builds on one machine and runs on others. Zig names it with underscores and Rust
# with dashes.
model=${MC_SERVER_BENCH_CPU:-native}
cpu=-Dcpu=$model
rust_cpu=-Ctarget-cpu=${model//_/-}

# The bench builds against Lightning Rod's protocol packages, and so does its Lightning Rod server.
if wants bench lightning-rod; then git submodule update --init servers/lightning-rod; fi
if wants bench; then zig build -Drelease "$cpu"; fi

# Vanilla 26.2, checked against the hash Mojang publishes. It also generates the worlds.
jar=servers/vanilla/server.jar
sha=823e2250d24b3ddac457a60c92a6a941943fcd6a
if wants vanilla terrain-real terrain-flat terrain-wide terrain-tiled paper paper-antifreecam folia fabric-optimized; then
  if ! echo "$sha  $jar" | sha1sum --check --status 2>/dev/null; then
    mkdir -p servers/vanilla
    curl -fsSL -o "$jar" "https://piston-data.mojang.com/v1/objects/$sha/server.jar"
    echo "$sha  $jar" | sha1sum --check
  fi
  # Its launcher unpacks libraries on first start, here once rather than in a measured startup.
  if [ ! -d servers/vanilla/bundle/versions ]; then
    scratch=$(mktemp -d)
    (cd "$scratch" && java -DbundlerRepoDir="$root/servers/vanilla/bundle" -jar "$root/$jar" --help > /dev/null)
    rm -rf "$scratch"
  fi
fi

# The worlds runs start from, pregenerated once so no run generates terrain: real terrain from the
# seed and flat terrain, each a square of radius 64 chunks, and wide flat terrain far enough out
# for the views of 256 players spread apart. Vanilla generates them for every server reading
# vanilla worlds, Lightning Rod imports them, and SteelMC generates the same chunks itself, below.
# Each world is a target of its own for each that makes it, so CI makes every one in a job of its
# own and runs on a world wait only for that world: `terrain-real`, `terrain-flat` and
# `terrain-wide` make vanilla's.
pregenerate() {
  [ -d "$build/worlds/$2/$1/${3:-world}" ] && return
  [ -x zig-out/bin/bench ] || zig build -Drelease "$cpu"
  ./zig-out/bin/bench pregen --server="$1" --terrain="$2"
}
for terrain in real flat wide tiled; do
  if wants "terrain-$terrain"; then pregenerate vanilla "$terrain"; fi
done

# Lightning Rod, built from its packages by the bench as a server outside its repository would be,
# with the tool that imports vanilla worlds into it.
if wants lightning-rod; then
  zig build -Drelease "$cpu" lightning-rod -p "$build/lightning-rod"
  record lightning-rod
  (cd servers/lightning-rod/tools/world-import && zig build -Doptimize=ReleaseSafe "$cpu" -p "$build/world-import")
fi

# Lightning Rod's worlds: vanilla's imported with their caches built, as vanilla saves its light
# with the chunks, again whenever its commit changes, as another commit may read the caches of an
# earlier import as outdated and start cold. `import-real`, `import-flat` and `import-wide` import
# each world.
import_world() {
  pregenerate vanilla "$1"
  local output=$build/worlds/$1/lightning-rod
  [ -d "$output" ] && cmp -s "$output.version" "$build/versions/lightning-rod" && return
  rm -rf "$output"
  "$build/world-import/bin/world-import" --input "$build/worlds/$1/vanilla/world" --output "$output" --skip-unsupported --prewarm
  cp "$build/versions/lightning-rod" "$output.version"
}
for terrain in real flat wide tiled; do
  if wants "import-$terrain"; then import_world "$terrain"; fi
done

# Pumpkin, as its README builds it. Its generated data crate needs a deep stack to compile. It
# names only the latest stable Rust, so where rustup manages Rust it builds with 1.98.0, the stable
# release when its pinned commit was made, rather than whichever is latest on the day.
if wants pumpkin; then
  git submodule update --init --recursive servers/pumpkin
  rust=1.98.0
  if command -v rustup > /dev/null; then rustup toolchain install --profile minimal "$rust"; fi
  (cd servers/pumpkin && RUSTUP_TOOLCHAIN=$rust RUST_MIN_STACK=1073741824 RUSTFLAGS="$rust_cpu" cargo build --release)
  record pumpkin
fi

# SteelMC, with the nightly toolchain it pins: from rustup where rustup manages Rust, otherwise
# from its own dev shell. It links with lld. Its build downloads vanilla assets, which the
# sandbox of its Nix package cannot.
if wants steel; then
  git submodule update --init --recursive servers/steel
  # Its console reads commands only from a terminal, and the bench pipes them for tick queries.
  # It has no forceload, which generating the same real terrain as vanilla's takes. Its logger asks
  # crossterm for the terminal size on every line, which on a pipe runs `tput` twice a line.
  for patch in "$root/patches/steel-console-stdin.patch" "$root/patches/steel-forceload.patch" "$root/patches/steel-logger-size.patch"; do
    git -C servers/steel apply --reverse --check "$patch" 2>/dev/null || git -C servers/steel apply "$patch"
  done
  # The CPU model joins the target flags its own config sets, which RUSTFLAGS would replace.
  flags="target.x86_64-unknown-linux-gnu.rustflags=[\"$rust_cpu\"]"
  if command -v rustup > /dev/null; then
    (cd servers/steel && rustup toolchain install && cargo build --release -p steel --config "$flags")
  else
    (cd servers/steel && nix develop "path:$PWD" --command cargo build --release -p steel --config "$flags")
  fi
  record steel
fi

# SteelMC's worlds: the same squares of chunks that vanilla pregenerates for every other server,
# generated by SteelMC into its own format, again whenever its build changes. `steel-real`,
# `steel-flat` and `steel-wide` make each world.
steel_world() {
  local output=$build/worlds/$1/steel
  [ -d "$output" ] && cmp -s "$output.version" "$build/versions/steel" && return
  rm -rf "$output"
  pregenerate steel "$1" saves
  cp "$build/versions/steel" "$output.version"
}
for terrain in real flat wide tiled; do
  if wants "steel-$terrain"; then steel_world "$terrain"; fi
done

# Downloads a list of `file url sha512` lines into a directory, each checked against the hash
# Modrinth publishes.
fetch_mods() {
  mkdir -p "$1"
  while read -r file url sha; do
    if ! echo "$sha  $1/$file" | sha512sum --check --status 2>/dev/null; then
      curl -fsSL -o "$1/$file" "$url"
      echo "$sha  $1/$file" | sha512sum --check
    fi
  done
}

# Paper and Folia, Paper's fork that ticks regions of the world on threads of their own, from
# PaperMC's download service, checked against the hash it publishes. Their launchers patch the
# vanilla jar and fetch libraries once here, and every run links them.
paper_family() {
  local jar=servers/$1/$1.jar
  if ! echo "$3  $jar" | sha256sum --check --status 2>/dev/null; then
    mkdir -p "servers/$1"
    curl -fsSL -o "$jar" "https://fill-data.papermc.io/v1/objects/$3/$1-26.2-$2.jar"
    echo "$3  $jar" | sha256sum --check
  fi
  [ -d "servers/$1/versions" ] || (cd "servers/$1" && java -Dpaperclip.patchonly=true -jar "$1.jar")
}
# Paper 26.2 build 135.
if wants paper paper-antifreecam; then
  paper_family paper 135 ef3dbc68b013deafdbbee3bebf1ba351671ebcda94a8f136809b7532d5ba2fe1
fi
# Paper with FPAntiFreecam 1.5.3.1, which sends each player only what it can see, and PacketEvents
# 2.14.0, which it needs, pinned to their Modrinth releases.
if wants paper-antifreecam; then
  fetch_mods servers/paper/plugins-antifreecam <<'PLUGINS'
FPAntiFreeCam-1.5.31.jar https://cdn.modrinth.com/data/NodGIhss/versions/XKBQ5cRO/FPAntiFreeCam-1.5.31.jar 3156c73943a8758007425375582314f1d810f3766c32f33cc73ce9724c3e9adc2e093da4e210e8d1f31709795a310eba72bc2126f2efc19f08f4d42e2bdf3322
packetevents-spigot-2.14.0.jar https://cdn.modrinth.com/data/HYKaKraK/versions/m78nFxYg/packetevents-spigot-2.14.0.jar 18a942cb55f64783a63b28deea2cebbbe782e5d6a1089f6700430e183bfbce0a45398a640ed0dff4361b55190dcf47017f2ca7788f4a5c8c9efad1f549a63fe3
PLUGINS
fi
# Folia 26.2 build 7, its newest for 26.2.
if wants folia; then
  paper_family folia 7 128a634192261cd38bb4a5dc54075018a0f896fd6c6f529e37dca6e99e32b3b3
fi

# Fabric Loader 0.20.1 from its installer, checked against the hash Fabric's Maven publishes, and
# the mods pinned to their Modrinth releases for 26.2.
if wants fabric-optimized; then
  mkdir -p servers/fabric
  installer=servers/fabric/fabric-installer-1.1.2.jar
  if ! echo "74685b5a0178c4dabd4be741a276d35c59b5ec96  $installer" | sha1sum --check --status 2>/dev/null; then
    curl -fsSL -o "$installer" https://maven.fabricmc.net/net/fabricmc/fabric-installer/1.1.2/fabric-installer-1.1.2.jar
    echo "74685b5a0178c4dabd4be741a276d35c59b5ec96  $installer" | sha1sum --check
  fi
  [ -f servers/fabric/fabric-server-launch.jar ] || java -jar "$installer" server -mcversion 26.2 -loader 0.20.1 -dir servers/fabric
  fetch_mods servers/fabric/mods <<'MODS'
ferritecore-9.0.0-fabric.jar https://cdn.modrinth.com/data/uXXizFIs/versions/d5ddUdiB/ferritecore-9.0.0-fabric.jar d81fa97e11784c19d42f89c2f433831d007603dd7193cee45fa177e4a6a9c52b384b198586e04a0f7f63cd996fed713322578bde9a8db57e1188854ae5cbe584
lithium-fabric-0.25.3+mc26.2.jar https://cdn.modrinth.com/data/gvQqBUqZ/versions/f7vZ0VWU/lithium-fabric-0.25.3%2Bmc26.2.jar 148b638f3c6229fbaf487120a2344a0af5e411a5aa6533d5db9d75da0a8c0d8304f63eb4cca13f4d03b2c9b4c23d559dd74c1d832422ef8a3087bd005e62a8bd
ScalableLux-fabric-0.3.0-alpha.0.3-all.jar https://cdn.modrinth.com/data/Ps1zyz6x/versions/EKLUURiy/ScalableLux-fabric-0.3.0-alpha.0.3-all.jar ea1551c8728a726f6ee82fed3040af52791943ef99f6b63428ed770797f60677e0160975ad59ad0f51bcd4a4ec2b5da39c6913ab2379f2e25d2397132d469a94
krypton-0.3.1.jar https://cdn.modrinth.com/data/fQEb0iXm/versions/5WeL0Nkz/krypton-0.3.1.jar b8d9af34cd0050493afb8a6232cb8f785daa9d8887b7045f6e6a53c6bb9b5ffc4318fd9b0347a940eacfeba4773f10cb80ae0be1e79ce4c1888f96eda21e564e
MODS
fi
