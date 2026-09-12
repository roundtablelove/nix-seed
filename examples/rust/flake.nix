{

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    crane.url = "github:ipetkov/crane";
    nix-seed = {
      url = ./../..;
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs: {
    packages =
      # systems from nixpkgs.lib, not nix-seed: referencing
      # `inputs.nix-seed.inputs` forces nix-seed's whole flake evaluation
      # (mkFlake + every flakeModule), which the seed no longer bakes.
      inputs.nixpkgs.lib.genAttrs inputs.nixpkgs.lib.systems.flakeExposed (
        system:
        let
          pkgs = inputs.nixpkgs.legacyPackages.${system};
          craneLib = inputs.crane.mkLib pkgs;

          commonArgs = {
            src = craneLib.cleanCargoSource ./.;
            strictDeps = true;
          };

          # dependencies compiled on their own. baked into the seed via
          # the package's inputDerivation, so the consumer's offline build
          # recompiles only the crate itself, not serde et al.
          cargoArtifacts = craneLib.buildDepsOnly commonArgs;
        in
        {
          default = craneLib.buildPackage (commonArgs // { inherit cargoArtifacts; });

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
