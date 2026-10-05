{ pkgs }:
let
  # Generated from the paired upstream wheels; updated together in CI.
  sources = builtins.fromJSON (builtins.readFile ./sources.json);
  python = pkgs.python312.override {
    packageOverrides =
      final: _prev:
      let
        package =
          name: pin:
          let
            dependencies = map (dependency: final.${dependency}) pin.dependencies;
            src = if pin.source ? rev then pkgs.fetchgit pin.source else pkgs.fetchurl pin.source;
          in
          final.buildPythonPackage {
            pname = name;
            inherit src dependencies;
            inherit (pin) version;
            format = if pin.source ? rev then "pyproject" else "wheel";
            build-system = pkgs.lib.optionals (pin.source ? rev) [ final.setuptools ];
            dontStrip = true;
            # Both OpenCV distributions provide cv2; share the headless one.
            pythonRemoveDeps = pkgs.lib.optional (name == "mlx-vlm") "opencv-python";
            # dyld resolves @loader_path at the extension's real store path.
            postInstall = pkgs.lib.optionalString (name == "mlx") ''
              ln -s ${final.mlx-metal}/${python.sitePackages}/mlx/lib "$out/${python.sitePackages}/mlx/lib"
            '';
          };
      in
      builtins.mapAttrs package sources;
  };
  runtimePackages = map (name: python.pkgs.${name}) (
    builtins.filter (name: name != "vllm") (builtins.attrNames sources)
  );
in
python.pkgs.toPythonApplication (
  python.pkgs.vllm.overridePythonAttrs (old: {
    # Include the plugin and all resolved extras.
    dependencies = runtimePackages;
    # Spawned workers invoke Python directly, bypassing the entry-point wrapper.
    makeWrapperArgs = [
      "--prefix PYTHONPATH : ${placeholder "out"}/${python.sitePackages}"
      "--prefix PYTHONPATH : ${python.pkgs.makePythonPath runtimePackages}"
    ];
    pythonImportsCheck = [
      "vllm.entrypoints.cli.main"
      "vllm_metal"
      "filelock"
    ];
    meta = (old.meta or { }) // {
      mainProgram = "vllm";
    };
  })
)
