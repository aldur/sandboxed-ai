{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { nixpkgs, ... }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};

      llama-cpp =
        (pkgs.llama-cpp.override {
          cpuArchDynamicDispatch = false; # Incompatible with a static binary.
        }).overrideAttrs
          (
            finalAttrs: old: {
              # Optionally: bump to a more recent version than nixpkgs'
              version = "9623";
              src = pkgs.fetchFromGitHub {
                owner = "ggml-org";
                repo = "llama.cpp";
                tag = "b${finalAttrs.version}";
                hash = "sha256-fulwV/RFJYqry6nrHRZ9BKcKorX0xQiH0GaTUYBoIvc=";
                leaveDotGit = true;
                postFetch = ''
                  git -C "$out" rev-parse --short HEAD > $out/COMMIT
                  find "$out" -name .git -print0 | xargs -0 rm -rf
                '';
              };
              npmDepsHash = "sha256-TU4Gv+dd48WDpswhfVtm79IVIOwoCXz1fZ/DI/z40Wg=";
              cmakeFlags =
                builtins.filter (f: builtins.match "-D(GGML_NATIVE|BUILD_SHARED_LIBS).*" f == null) (
                  old.cmakeFlags or [ ]
                )
                ++ [
                  "-DGGML_NATIVE=ON" # Enable CPU optimizations for M series.
                  "-DBUILD_SHARED_LIBS=OFF" # Make it a fat static binary.
                ];
              preConfigure = ''
                export NIX_ENFORCE_NO_NATIVE=0
                ${old.preConfigure or ""}
              '';
            }
          );

      llm = pkgs.llm.withPlugins { llm-llama-server = true; };

      # Thin launcher so `sandbox` works on PATH inside the dev shell.
      # sandbox.sh resolves its profiles/state relative to its own location, so
      # exec the working-tree copy rather than a Nix store copy. Resolve it from
      # the current directory at call time (walk up to the nearest sandbox.sh):
      # this makes `sandbox` behave exactly like ./sandbox.sh. A path frozen at
      # shell entry silently diverges once you switch worktree/branch or edit a
      # profile, so `sandbox` would run a stale .sb while ./sandbox.sh runs yours.
      sandbox = pkgs.writeShellScriptBin "sandbox" ''
        dir="$PWD"
        while [ "$dir" != "/" ] && [ ! -x "$dir/sandbox.sh" ]; do
          dir="$(dirname "$dir")"
        done
        [ -x "$dir/sandbox.sh" ] || {
          echo "sandbox: no sandbox.sh found from $PWD upward" >&2
          exit 1
        }
        exec "$dir/sandbox.sh" "$@"
      '';
    in
    {
      packages.${system} = {
        inherit llama-cpp llm;
        default = llama-cpp;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          llama-cpp
          llm
          pkgs.opencode
          sandbox
        ];
      };
    };
}
