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
              version = "9840";
              src = pkgs.fetchFromGitHub {
                owner = "ggml-org";
                repo = "llama.cpp";
                tag = "b${finalAttrs.version}";
                hash = "sha256-LugzC4UmzC49tRF/DXb3dnXPW4BJkoAaKETrMmDhTsY=";
                leaveDotGit = true;
                postFetch = ''
                  git -C "$out" rev-parse --short HEAD > $out/COMMIT
                  find "$out" -name .git -print0 | xargs -0 rm -rf
                '';
              };
              npmDepsHash = "sha256-X1DZgmhS/zHTqDT5zq0kywwntthcJ9vRXeqyO3zz6UU=";
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

      # Hugging Face's llama.cpp provider for pi: a single index.ts extension
      # with no npm dependencies (only an optional peer-dep on pi itself), so
      # the source tree is all we need. It is loaded with `pi -e <dir>/index.ts`
      # rather than the runtime `pi install` (which git-clones over the network
      # into a mutable ~/.pi and edits pi settings) — keeping it pinned and
      # offline, in the same spirit as llm.withPlugins and the bundled profiles.
      pi-llama = pkgs.fetchFromGitHub {
        owner = "huggingface";
        repo = "pi-llama";
        rev = "a307df2e23b9ad213bd925c1db9a12d540146d4e";
        hash = "sha256-rCvyW6d4HDp/6kZ3zHnw5SrQNdxTEPQTRCQhJvnFLB4=";
      };

      # `pi` bundled with the llama-cpp plugin: the upstream agent wrapped so the
      # pinned pi-llama extension auto-loads on every run (`pi -e <store>/index.ts`,
      # a position-independent repeatable flag) — no `pi install`, no flag to
      # remember. Unsandboxed; for the seatbelt-wrapped variant use
      # `sandboxed-ai pi`. The plugin finds your server via LLAMA_BASE_URL
      # (default http://localhost:8080/v1).
      pi = pkgs.runCommand "pi-with-llama-${pkgs.pi-coding-agent.version}"
        {
          nativeBuildInputs = [ pkgs.makeWrapper ];
          meta = pkgs.pi-coding-agent.meta // {
            mainProgram = "pi";
            description = "pi-coding-agent bundled with the huggingface/pi-llama llama.cpp plugin";
          };
        }
        ''
          makeWrapper ${pkgs.lib.getExe pkgs.pi-coding-agent} $out/bin/pi \
            --add-flags "-e ${pi-llama}/index.ts"
        '';

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
          install -m444 common.sb llama-server.sb llm.sb opencode.sb pi.sb $libexec/
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
        inherit llama-cpp llm pi pi-llama sandboxed-ai;
        default = sandboxed-ai;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          llama-cpp
          llm
          pkgs.opencode
          pkgs.pi-coding-agent
          sandboxed-ai
        ];
      };
    };
}
