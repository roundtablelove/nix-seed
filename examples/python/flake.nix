{

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nix-seed = {
      url = ../..;
      inputs = {
        nixpkgs.follows = "nixpkgs";
        mkdocs-flake.inputs.pyproject-nix.follows = "pyproject-nix";
      };
    };
    pyproject-nix = {
      url = "github:kingarrrt/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs: {
    packages =
      # systems from nixpkgs.lib, not nix-seed: referencing
      # `inputs.nix-seed.inputs` forces nix-seed's whole flake evaluation
      # (mkFlake + every flakeModule), which the seed no longer bakes.
      inputs.nixpkgs.lib.genAttrs inputs.nixpkgs.lib.systems.flakeExposed
        (
          system:
          let
            pkgs = inputs.nixpkgs.legacyPackages.${system};
            project = inputs.pyproject-nix.lib.project.loadPyproject {
              projectRoot = ./.;
            };
            python = builtins.head (
              inputs.pyproject-nix.lib.util.filterPythonInterpreters {
                inherit (project) requires-python;
                inherit (pkgs) pythonInterpreters;
              }
            );
            # deliberately non-upstream: a patched dependency can never be
            # substituted from cache.nixos.org, so the caching workflows
            # have a real local build to amortise. let-bound, not exported:
            # a package attr would make mkSeed bake its *build* closure
            # (cmake, zstd src) into the seed, which the consumer -- who
            # only links the prebuilt outputs -- never needs.
            expensive = pkgs.zstd.overrideAttrs (previous: {
              pname = "${previous.pname}-nonsubstitutable";
              postPatch = (previous.postPatch or "") + ''
                echo '/* nix-seed benchmark */' >>lib/zstd.h
              '';
            });
          in
          {

            default =
              (python.pkgs.buildPythonPackage (
                pkgs.lib.recursiveUpdate (project.renderers.buildPythonPackage {
                  inherit python;
                }) { meta.mainProgram = "hello"; }
              )).overrideAttrs
                (previous: {
                  buildInputs = (previous.buildInputs or [ ]) ++ [ expensive ];
                });

            seed = inputs.nix-seed.lib.mkSeed {
              inherit pkgs;
              inherit (inputs) self;
              excludeInputs = [
                "devshell"
                "emanote"
                "git-hooks"
                "github-actions-nix"
                "gitlab-ci"
                "mkdocs-flake"
                "nix-github-actions"
                "nix-unit"
                "poetry2nix"
                "treefmt-nix"
              ];
            };

          }
        );
  };

}
