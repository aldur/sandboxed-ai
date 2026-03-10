{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    llama-cpp-src.url = "github:ggml-org/llama.cpp";
  };

  outputs =
    {
      self,
      nixpkgs,
      llama-cpp-src,
    }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};

      # The upstream flake auto-enables Metal on aarch64-darwin.
      # We flip GGML_NATIVE for CPU-specific optimizations and
      # disable shared libs so llama-server is a single binary.
      llama-cpp = llama-cpp-src.packages.${system}.default.overrideAttrs (old: {
        cmakeFlags =
          builtins.filter (
            f: builtins.match "-D(GGML_NATIVE|BUILD_SHARED_LIBS).*" f == null
          ) (old.cmakeFlags or [ ])
          ++ [
            "-DGGML_NATIVE=ON"
            "-DBUILD_SHARED_LIBS=OFF"
          ];
        preConfigure = ''
          export NIX_ENFORCE_NO_NATIVE=0
          ${old.preConfigure or ""}
        '';
      });

      llm = pkgs.llm.withPlugins { llm-llama-server = true; };
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
        ];
      };
    };
}
