{

  # a real, modest C dependency tree: curlMinimal links zlib among a
  # handful of others. zlib is patched non-substitutable so the closure
  # has an actual (small, fast) compile to amortise rather than a
  # cache.nixos.org pull -- the same idea as examples/python's patched
  # zstd, but here the overridden package is one curl genuinely links,
  # not one bolted on for the purpose.

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
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
        in
        {

          # curlMinimal.override, not a pkgs-wide overlay: only this one
          # package's zlib argument is replaced, everything else curl
          # links stays substitutable from cache.nixos.org.
          default = pkgs.curl.override {
            # deliberately non-upstream: a patched dependency can never be
            # substituted from cache.nixos.org, and curl rebuilds from
            # source behind it, so the caching workflows have a real
            # local build to amortise.
            zlib = pkgs.zlib.overrideAttrs (previous: {
              pname = "${previous.pname}-nonsubstitutable";
              # a leading newline: the upstream postPatch this appends to
              # is not guaranteed to end in one, and gluing onto its last
              # line breaks whatever command that line runs.
              postPatch = (previous.postPatch or "") + ''

                echo '/* nix-seed benchmark */' >>zlib.h
              '';
            });
          };

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
