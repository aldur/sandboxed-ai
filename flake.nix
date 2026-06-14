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
            ./opencode.sb
          ];
        };

        nativeBuildInputs = [ pkgs.makeWrapper ];
        dontConfigure = true;
        dontBuild = true;

        installPhase = ''
          runHook preInstall
          libexec=$out/libexec/sandboxed-ai
          install -Dm755 sandbox.sh $libexec/sandbox.sh
          install -m444 common.sb llama-server.sb llm.sb opencode.sb $libexec/
          makeWrapper $libexec/sandbox.sh $out/bin/sandboxed-ai \
            --prefix PATH : ${
              pkgs.lib.makeBinPath [
                pkgs.bash
                pkgs.coreutils
                pkgs.curl
                pkgs.gnugrep
                pkgs.gnused
                llama-cpp
                llm
                pkgs.opencode
              ]
            }
          runHook postInstall
        '';

        meta.mainProgram = "sandboxed-ai";
      };
    in
    {
      packages.${system} = {
        inherit llama-cpp llm sandboxed-ai;
        default = sandboxed-ai;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          llama-cpp
          llm
          pkgs.opencode
          sandboxed-ai
        ];
      };
    };
}
