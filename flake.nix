{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    dotfiles = {
      url = "github:aldur/dotfiles";
      inputs = {
        # We rely on `nixpkgs-darwin` to fetch the mlx wheel and its hash.
        # We do not override it on purpose.
        nixpkgs.follows = "nixpkgs";
        nixpkgs-unstable.follows = "nixpkgs";
        agenix.follows = "";
        clipshare.follows = "";
        dashp.follows = "";
        detnix.follows = "";
        home-manager.follows = "";
        neovim-nightly-overlay.follows = "";
        nix-index-database.follows = "";
        nixCats.follows = "";
        preservation.follows = "";
      };
    };
  };

  outputs =
    { nixpkgs, dotfiles, ... }:
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
              version = "10238";
              src = pkgs.fetchFromGitHub {
                owner = "ggml-org";
                repo = "llama.cpp";
                tag = "b${finalAttrs.version}";
                hash = "sha256-l8vRqBbWnJeTIVB0O+LugUco4Y969+vDN0S+kz3ws5k=";
                leaveDotGit = true;
                postFetch = ''
                  git -C "$out" rev-parse --short HEAD > $out/COMMIT
                  find "$out" -name .git -print0 | xargs -0 rm -rf
                '';
              };
              npmDepsHash = "sha256-B7uEynAG70a3xauBKc20RuFa9cnWaWzVBCh+LPLBnIM=";
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

      # MLX equivalent of llama-server: `mlx_lm.server` (ml-explore/mlx-lm)
      # speaks the same OpenAI-compatible HTTP API (/v1/chat/completions,
      # /v1/models, /health) on localhost.
      #
      # nixpkgs builds the `mlx` python package with MLX_BUILD_METAL=OFF (the
      # `metal` shader compiler is proprietary and unavailable in the build
      # sandbox), so it does no GPU acceleration. Metal support comes from the
      # dotfiles `mlx` overlay (prebuilt Apple-Silicon PyPI wheel), applied to
      # a nixpkgs instance of its own so the main `pkgs` — and its binary
      # cache hits — stay untouched by the python package-set extensions.
      pkgsMlx = import nixpkgs {
        inherit system;
        overlays = [ dotfiles.overlays.mlx ];
      };

      # The interpreter whose package set carries the Metal wheel. Selected by
      # the overlay (`mlx-python`) to match the CPython the wheel hash is
      # pinned for — not hardcoded here, so a wheel/Python bump in dotfiles
      # carries over with the next flake update.
      mlxPython = pkgsMlx.mlx-python;

      # `mlx_lm.server` (and the rest of the mlx_lm.* CLI) on PATH.
      mlx-lm = mlxPython.pkgs.toPythonApplication mlxPython.pkgs.mlx-lm;

      # `mlx_vlm.server`: OpenAI-compatible server for MLX *vision* models. Same
      # Metal-enabled package set; sandbox.sh picks it automatically for models
      # whose config carries a vision tower.
      mlx-vlm = mlxPython.pkgs.toPythonApplication (
        mlxPython.pkgs.mlx-vlm.overrideAttrs (old: {
          propagatedBuildInputs = (old.propagatedBuildInputs or [ ]) ++ [
            mlxPython.pkgs.torch
            mlxPython.pkgs.torchvision
          ];
        })
      );

      # `pi` bundled with the pinned huggingface/pi-llama llama.cpp plugin
      # (auto-loaded via `pi -e <store>/index.ts` — no `pi install`, no
      # network) and telemetry off. Packaged in aldur/dotfiles; through the
      # input follows it builds against this flake's nixpkgs, so the agent
      # version matches the `pkgs.pi-coding-agent` used elsewhere here.
      # Unsandboxed; for the seatbelt-wrapped variant use `sandboxed-ai pi`.
      # The plugin finds your server via LLAMA_BASE_URL (default
      # http://localhost:8080/v1). Its pin is bumped by the dotfiles CI and
      # lands here with flake.lock updates of the `dotfiles` input.
      pi = dotfiles.packages.${system}.pi;
      pi-llama = pi.plugins.pi-llama;

      # Self-contained launcher exposed as `sandboxed-ai` on PATH. Bundles
      # sandbox.sh together with the seatbelt profiles (*.sb) and the runtime it
      # shells out to, so it needs nothing from the working tree. Profiles are
      # read from next to the script in the store; writable state (models,
      # cache, generated config) lives under the directory you run it from.
      # Named `sandboxed-ai`, not `sandbox`, to avoid colliding with shells that
      # already define a `sandbox` abbreviation/function.
      sandboxed-ai = pkgs.stdenv.mkDerivation {
        pname = "sandboxed-ai";
        version = "0.2.0";

        src = pkgs.lib.fileset.toSource {
          root = ./.;
          fileset = pkgs.lib.fileset.unions [
            ./sandbox.sh
            ./common.sb
            ./llama-server.sb
            ./llm.sb
            ./mlx-server.sb
            ./opencode.sb
            ./pi.sb
          ];
        };

        nativeBuildInputs = [ pkgs.makeWrapper ];
        dontConfigure = true;
        dontBuild = true;

        installPhase = ''
          runHook preInstall
          libexec=$out/libexec/sandboxed-ai
          install -Dm755 sandbox.sh $libexec/sandbox.sh
          install -m444 common.sb llama-server.sb llm.sb mlx-server.sb opencode.sb pi.sb $libexec/
          makeWrapper $libexec/sandbox.sh $out/bin/sandboxed-ai \
            --set SANDBOXED_AI_PROG sandboxed-ai \
            --set PI_LLAMA_DIR ${pi-llama} \
            --prefix PATH : ${
              pkgs.lib.makeBinPath [
                pkgs.bash
                pkgs.coreutils
                pkgs.curl
                pkgs.gnugrep
                pkgs.gnused
                llama-cpp
                llm
                mlx-lm
                mlx-vlm
                pkgs.opencode
                pkgs.pi-coding-agent
              ]
            }
          runHook postInstall
        '';

        meta.mainProgram = "sandboxed-ai";
      };
    in
    {
      packages.${system} = {
        inherit
          llama-cpp
          llm
          mlx-lm
          mlx-vlm
          pi
          pi-llama
          sandboxed-ai
          ;
        default = sandboxed-ai;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          llama-cpp
          llm
          mlx-lm
          mlx-vlm
          pkgs.opencode
          pkgs.pi-coding-agent
          sandboxed-ai
        ];
      };
    };
}
