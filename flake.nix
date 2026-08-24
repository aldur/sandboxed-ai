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
              version = "10456";
              src = pkgs.fetchFromGitHub {
                owner = "ggml-org";
                repo = "llama.cpp";
                tag = "b${finalAttrs.version}";
                hash = "sha256-ykW276JlWJqyBv1eoCEnJ8RAm67Ux7YsscesRSu6fRU=";
                leaveDotGit = true;
                postFetch = ''
                  git -C "$out" rev-parse --short HEAD > $out/COMMIT
                  find "$out" -name .git -print0 | xargs -0 rm -rf
                '';
              };
              npmDepsHash = "sha256-2Q7XhaLAArmviOLdQsNbYTfdyDE5pW9lR26cRHEVl9k=";
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
        overlays = [
          dotfiles.overlays.mlx
          # Serve on a UNIX domain socket when --host ends in .sock,
          # mirroring llama-server's convention (see sandbox.sh --host).
          # Applied inside the package set — not on the leaf application — so
          # mlx-vlm, which depends on mlx-lm, shares the same patched build.
          (final: prev: {
            pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
              (pyFinal: pyPrev: {
                mlx-lm = pyPrev.mlx-lm.overrideAttrs (old: {
                  patches = (old.patches or [ ]) ++ [ ./patches/mlx-lm-unix-socket.patch ];
                });
              })
            ];
          })
        ];
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
          # Serve on a UNIX domain socket when --host ends in .sock,
          # mirroring llama-server's convention (see sandbox.sh --host).
          patches = (old.patches or [ ]) ++ [ ./patches/mlx-vlm-unix-socket.patch ];
          # mlx 0.32 rejects the zero-size AvgPool2d kernel this test's
          # Gemma3 config computes; mlx-vlm 0.4.4 predates that mlx.
          # One known-incompatible test — the rest of the suite still runs.
          disabledTests = (old.disabledTests or [ ]) ++ [
            "test_gemma3_input_embeddings"
          ];
        })
      );

      # MTPLX (github.com/youssofal/MTPLX): MLX server that decodes with
      # the model's own MTP heads. Pure-python PyPI release, built in the
      # Metal-enabled python set so it shares the same mlx (and the
      # unix-socket-patched mlx-lm) as the mlx servers. Built from the
      # sdist, not the wheel: nix-update (see update-pinned-packages.yml)
      # resolves new versions from fetchPypi's mirror://pypi URL, which
      # only the sdist form produces.
      # Exported under packages for nix-update and the e2e suite's
      # flake_bin, like llama-cpp — never for a shell PATH: it reaches a
      # user only through the sandboxed-ai wrapper (`sandboxed-ai mtplx`).
      mtplx = mlxPython.pkgs.toPythonApplication (
        mlxPython.pkgs.buildPythonPackage rec {
          pname = "mtplx";
          version = "2.9.1";
          pyproject = true;
          src = pkgs.fetchPypi {
            inherit pname version;
            hash = "sha256-czLIhkQmOZmfDAPYl8M0R/Er41AXUuOUB8/c3tGgQr4=";
          };
          # Serve on a UNIX domain socket when --host ends in .sock,
          # mirroring llama-server's convention (see sandbox.sh --host).
          patches = [ ./patches/mtplx-unix-socket.patch ];
          build-system = with mlxPython.pkgs; [
            setuptools
            wheel
          ];
          # Upstream pins tight ranges on the Metal stack; the package set
          # carries what the overlay's wheel provides. Relax those pins
          # rather than skip the check, so a truly missing dependency
          # still fails the build.
          pythonRelaxDeps = [
            "mlx"
            "mlx-lm"
            "transformers"
          ];
          propagatedBuildInputs = with mlxPython.pkgs; [
            fastapi
            huggingface-hub
            # The 'server' extra: grammar-constrained output (JSON schema,
            # tool calls). Without it those requests fail at runtime.
            llguidance
            mlx
            # A bare `mlx-lm` resolves to the outer `let` binding, which
            # is the CLI application: `let` wins over `with` in Nix. The
            # application has no `pythonModule` attribute, so
            # makePythonPath below would drop it. Name the python module
            # explicitly.
            mlxPython.pkgs.mlx-lm
            nanobind
            numpy
            pillow
            pydantic
            rich
            safetensors
            transformers
            uvicorn
          ];
          # `mtplx serve` starts `sys.executable -m mtplx.server.openai`
          # as a child process. Nix adds the site directories to the
          # entry script only, not to the interpreter. The child process
          # thus fails with ModuleNotFoundError. Export the same
          # directories as PYTHONPATH so the child process finds them.
          makeWrapperArgs = [
            "--prefix PYTHONPATH : ${placeholder "out"}/${mlxPython.sitePackages}"
            "--prefix PYTHONPATH : ${mlxPython.pkgs.makePythonPath propagatedBuildInputs}"
          ];
          # Upstream's tests need Metal, which the nix build sandbox does
          # not have (the same reason nixpkgs builds mlx GPU-less), so no
          # check phase; at least prove the package imports against this
          # dependency set.
          pythonImportsCheck = [ "mtplx" ];
        }
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
      # caches, per-tool homes) lives under $XDG_STATE_HOME/sandboxed-ai.
      # Named `sandboxed-ai`, not `sandbox`, to avoid colliding with shells that
      # already define a `sandbox` abbreviation/function.
      sandboxed-ai = pkgs.stdenv.mkDerivation {
        pname = "sandboxed-ai";
        version = "0.2.0";

        src = pkgs.lib.fileset.toSource {
          root = ./.;
          # sandbox.sh plus every seatbelt profile — one filter, so a new
          # profile snippet is picked up here and by installPhase's glob
          # without touching this file.
          fileset = pkgs.lib.fileset.unions [
            ./sandbox.sh
            ./hf.sh
            (pkgs.lib.fileset.fileFilter (f: f.hasExt "sb") ./profiles)
          ];
        };

        nativeBuildInputs = [ pkgs.makeWrapper ];
        dontConfigure = true;
        dontBuild = true;

        installPhase = ''
          runHook preInstall
          libexec=$out/libexec/sandboxed-ai
          install -Dm755 sandbox.sh $libexec/sandbox.sh
          install -Dm444 hf.sh $libexec/hf.sh
          install -Dm444 -t $libexec/profiles profiles/*.sb
          makeWrapper $libexec/sandbox.sh $out/bin/sandboxed-ai \
            --set SANDBOXED_AI_PROG sandboxed-ai \
            --set PI_LLAMA_DIR ${pi-llama} \
            --prefix PATH : ${
              pkgs.lib.makeBinPath [
                pkgs.bash
                pkgs.coreutils
                pkgs.curl
                pkgs.findutils
                pkgs.gnugrep
                pkgs.gnused
                llama-cpp
                llm
                mlx-lm
                mlx-vlm
                mtplx
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
          mtplx
          pi
          pi-llama
          sandboxed-ai
          ;
        default = sandboxed-ai;
      };

      # Only the sandboxed entry point, on purpose: the wrapper pins its
      # tool binaries via its own PATH prefix, so neither shell needs to
      # name — or put on PATH — any binary that would run outside a
      # sandbox. The e2e shell adds what tests/e2e.sh itself runs (the
      # suite resolves the model toolchain from the flake, not from PATH).
      devShells.${system} = {
        default = pkgs.mkShell { packages = [ sandboxed-ai ]; };
        e2e = pkgs.mkShell {
          packages = [
            sandboxed-ai
            pkgs.python3
          ];
        };
      };
    };
}
