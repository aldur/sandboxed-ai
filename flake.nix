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
              version = "9621";
              src = pkgs.fetchFromGitHub {
                owner = "ggml-org";
                repo = "llama.cpp";
                tag = "b${finalAttrs.version}";
                hash = "sha256-btVJatQi0efHo2XMFXn+SWqhZUigUYKfaVJiznD9V4Y=";
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
      # sandbox.sh resolves its profiles/state relative to its own location,
      # so exec the working-tree copy rather than a Nix store copy.
      sandbox = pkgs.writeShellScriptBin "sandbox" ''
        exec "''${SANDBOXED_AI_ROOT:-$PWD}/sandbox.sh" "$@"
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

        # Point the `sandbox` launcher at the repo root so it can find
        # sandbox.sh and its sibling .sb profiles regardless of cwd.
        shellHook = ''
          export SANDBOXED_AI_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
        '';
      };
    };
}
