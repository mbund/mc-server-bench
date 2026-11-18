#!/usr/bin/env bash
# Builds the servers named, or every one, at its pinned version, with the bench and the worlds
# they read. Steps already done are skipped. `bench` builds only the bench, and the targets named
# after a terrain only that world for one server family, which CI makes once in jobs of their own
# and shares with the rest.
# Usage: ./setup.sh [vanilla|lightning-rod|pumpkin|steel|paper|paper-antixray-1|fabric|fabric-occlusion|bench
#                   |terrain-real|terrain-flat|terrain-wide|import-real|import-flat|import-wide|steel-real|steel-flat|steel-wide]...
set -euo pipefail
cd "$(dirname "$0")"
# The flake's lock pins every toolchain, so local builds happen inside its shell. CI installs the
# same versions itself, which is faster than Nix there, and sets MC_SERVER_BENCH_SHELL.
if [ -z "${MC_SERVER_BENCH_SHELL:-}" ]; then exec nix develop --command "$0" "$@"; fi
root=$PWD
build=$root/servers/build
mkdir -p "$build/versions"
targets=" ${*:-bench vanilla lightning-rod pumpkin steel paper paper-antixray-1 fabric fabric-occlusion terrain-real terrain-flat terrain-wide import-real import-flat import-wide steel-real steel-flat steel-wide} "
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
git submodule update --init servers/lightning-rod
if wants bench; then zig build -Drelease "$cpu"; fi

# Vanilla 26.2, checked against the hash Mojang publishes. It also generates the worlds.
jar=servers/vanilla/server.jar
sha=823e2250d24b3ddac457a60c92a6a941943fcd6a
if wants vanilla terrain-real terrain-flat terrain-wide paper paper-antixray-1 fabric fabric-occlusion; then
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
for terrain in real flat wide; do
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
for terrain in real flat wide; do
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
  # It has no forceload, which generating the same real terrain as vanilla's takes.
  for patch in "$root/patches/steel-console-stdin.patch" "$root/patches/steel-forceload.patch"; do
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
for terrain in real flat wide; do
  if wants "steel-$terrain"; then steel_world "$terrain"; fi
done

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
# Downloads a list of `file url sha512` lines into a directory.
fetch_mods() {
  mkdir -p "$1"
  while read -r file url sha; do
    if ! echo "$sha  $1/$file" | sha512sum --check --status 2>/dev/null; then
      curl -fsSL -o "$1/$file" "$url"
      echo "$sha  $1/$file" | sha512sum --check
    fi
  done
}
if wants fabric fabric-occlusion; then
  mkdir -p servers/fabric
  installer=servers/fabric/fabric-installer-1.1.2.jar
  if ! echo "74685b5a0178c4dabd4be741a276d35c59b5ec96  $installer" | sha1sum --check --status 2>/dev/null; then
    curl -fsSL -o "$installer" https://maven.fabricmc.net/net/fabricmc/fabric-installer/1.1.2/fabric-installer-1.1.2.jar
    echo "74685b5a0178c4dabd4be741a276d35c59b5ec96  $installer" | sha1sum --check
  fi
  [ -f servers/fabric/fabric-server-launch.jar ] || java -jar "$installer" server -mcversion 26.2 -loader 0.20.1 -dir servers/fabric
  fetch_mods servers/fabric/mods <<'EOF'
ferritecore-9.0.0-fabric.jar https://cdn.modrinth.com/data/uXXizFIs/versions/d5ddUdiB/ferritecore-9.0.0-fabric.jar d81fa97e11784c19d42f89c2f433831d007603dd7193cee45fa177e4a6a9c52b384b198586e04a0f7f63cd996fed713322578bde9a8db57e1188854ae5cbe584
lithium-fabric-0.25.3+mc26.2.jar https://cdn.modrinth.com/data/gvQqBUqZ/versions/f7vZ0VWU/lithium-fabric-0.25.3%2Bmc26.2.jar 148b638f3c6229fbaf487120a2344a0af5e411a5aa6533d5db9d75da0a8c0d8304f63eb4cca13f4d03b2c9b4c23d559dd74c1d832422ef8a3087bd005e62a8bd
ScalableLux-fabric-0.3.0-alpha.0.3-all.jar https://cdn.modrinth.com/data/Ps1zyz6x/versions/EKLUURiy/ScalableLux-fabric-0.3.0-alpha.0.3-all.jar ea1551c8728a726f6ee82fed3040af52791943ef99f6b63428ed770797f60677e0160975ad59ad0f51bcd4a4ec2b5da39c6913ab2379f2e25d2397132d469a94
krypton-0.3.1.jar https://cdn.modrinth.com/data/fQEb0iXm/versions/5WeL0Nkz/krypton-0.3.1.jar b8d9af34cd0050493afb8a6232cb8f785daa9d8887b7045f6e6a53c6bb9b5ffc4318fd9b0347a940eacfeba4773f10cb80ae0be1e79ce4c1888f96eda21e564e
EOF
fi

# Fabric with Occlusion: the same mods, Fabric API, which Occlusion needs, and Occlusion itself.
# Occlusion has a release only for 26.3, so it builds from its pinned source with the patch that
# ports it to the 26.2 names.
if wants fabric-occlusion; then
  mods=servers/fabric/mods-occlusion
  mkdir -p "$mods"
  cp servers/fabric/mods/*.jar "$mods/"
  fetch_mods "$mods" <<'EOF'
fabric-api-0.161.0+26.2.jar https://cdn.modrinth.com/data/P7dR8mSH/versions/ewUK83HI/fabric-api-0.161.0%2B26.2.jar 2502fa5ade78e9a120b3747bc1a9a2167d6671743bea45bf115d3174c94121aeda87c549446d1a604a9c11fb828de17a551e3514ce42f3e93069dd14bdaee55b
EOF
  if [ ! -f "$mods/panda-occlusion-1.0.0+26.2.jar" ]; then
    git submodule update --init servers/occlusion
    patch=$root/patches/occlusion-26.2.patch
    git -C servers/occlusion apply --reverse --check "$patch" 2>/dev/null || git -C servers/occlusion apply "$patch"
    (cd servers/occlusion && ./gradlew --no-daemon -q build -x test)
    cp servers/occlusion/build/libs/panda-occlusion-1.0.0+26.2.jar "$mods/"
  fi
fi
