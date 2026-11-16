{
  description = "Reproducible benchmarks of Minecraft Java servers: vanilla, Lightning Rod and Pumpkin";

  # The lock pins nixpkgs, and with it every toolchain a run uses: Zig for the harness and
  # Lightning Rod, the JDK for vanilla, and Rust for Pumpkin.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in {
        devShells.default = pkgs.mkShell {
          name = "mc-server-bench";
          buildInputs = with pkgs; [
            zig
            jdk25
            rustc
            cargo
            git
            curl
            jq
            util-linux
          ];
          shellHook = ''
            export JAVA_HOME="${pkgs.jdk25}/lib/openjdk"
            # Lightning Rod's build runs Gradle from another directory, so the Zig cache needs a
            # path outside the repository, which Zig never shortens to a relative one.
            export ZIG_LOCAL_CACHE_DIR="$HOME/.cache/mc-server-bench/zig"
          '';
        };
      }
    );
}
