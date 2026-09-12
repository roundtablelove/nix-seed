{

  # the mirror image of the other examples: they make *building* expensive
  # (a patched, non-substitutable zstd; ripgrep's cargo closure) and keep
  # evaluation trivial. here the derivation is a one-line runCommand and
  # the cost is entirely in the evaluator.
  #
  # a seed cannot remove this cost: the consumer re-evaluates the flake on
  # every build, offline but in full, so eval time is a floor under every
  # job. it is measured here because it is the one part of a consumer's
  # build that nix-seed does not help with -- real flakes span 2s (a rust
  # binary) to ~18s (a large module set), and this example sits near the
  # top of that range deliberately. see doc/drv-seeds.md for the variant
  # that did remove it, and why it was dropped anyway.

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
          inherit (inputs.nixpkgs) lib;

          # ---- the load ----
          # a synthetic module set, run through the real module system:
          # option declaration, submodule instantiation, type checking
          # and definition merging are where NixOS, home-manager and
          # flake-parts configurations actually spend their seconds, so
          # this exercises the same code paths a heavy consumer flake
          # would -- deterministically, and without dragging a large
          # build closure in behind it.
          #
          # cost is roughly serviceCount * (settingCount + policyLayers)
          # type-checked definitions -- 300k here, ~20x a real NixOS
          # config. measured on a fast desktop core: 5.6s wall, 8s cpu.
          # wall < cpu because the collector marks in parallel, so a 2-core
          # runner lands nearer the cpu number.
          # scale serviceCount to move it -- but memory scales with it too:
          # peak RSS is 1.0GB with the collector running, and 1.6GB under
          # GC_DONT_GC, should a consumer set it. that is the figure to
          # keep clear of the runner's 7GB.
          serviceCount = 6000;
          settingCount = 40;
          policyLayers = 10;

          names = map (index: "svc-${toString index}") (lib.range 1 serviceCount);

          serviceType = lib.types.submodule (
            { name, ... }: {
              options = {
                enable = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                };
                port = lib.mkOption {
                  type = lib.types.port;
                  default = 8000;
                };
                description = lib.mkOption {
                  type = lib.types.str;
                  default = "service ${name}";
                };
                settings = lib.mkOption {
                  type = lib.types.attrsOf (lib.types.either lib.types.int lib.types.str);
                  default = { };
                };
              };
            }
          );

          declare = {
            options.services = lib.mkOption {
              type = lib.types.attrsOf serviceType;
              default = { };
            };
          };

          # one module per service, as a real configuration would be split
          serviceModule = index: {
            services."svc-${toString index}" = {
              port = 8000 + index;
              settings = lib.listToAttrs (
                map (
                  key:
                  lib.nameValuePair "key-${toString key}" "value-${toString index}-${toString key}"
                ) (lib.range 1 settingCount)
              );
            };
          };

          # cross-cutting layers that each touch *every* service, the way
          # site-wide defaults do: this is what turns option merging from
          # linear into the dominant term.
          policyModule = layer: {
            services = lib.genAttrs names (name: {
              settings."policy-${toString layer}" = "${name}@${toString layer}";
            });
          };

          evaluated = lib.evalModules {
            modules = [
              declare
            ]
            ++ map serviceModule (lib.range 1 serviceCount)
            ++ map policyModule (lib.range 1 policyLayers);
          };

          # forcing the merged config is the point: every option above is
          # type-checked on the way into this string. note the values are
          # folded in, not just counted -- `attrsOf` checks values lazily,
          # so reading only `attrNames` would skip the type checking that
          # makes this expensive (and the example pointless).
          summary = lib.concatMapStringsSep "\n" (
            name:
            let
              service = evaluated.config.services.${name};
              settings = lib.concatStringsSep "," (
                lib.mapAttrsToList (key: value: "${key}=${toString value}") service.settings
              );
            in
            "${name} ${toString service.port} ${service.description} "
            + builtins.hashString "sha256" settings
          ) names;
        in
        {

          # deliberately trivial to *build*: no compiler, no src, no
          # patched dependency. the seed's whole value here is that the
          # summary above was computed at seed time.
          default =
            pkgs.runCommand "eval-heavy-report"
              {
                inherit summary;
                # one line per service is past the 128kB ceiling on a single
                # environment variable ("argument list too long"). passAsFile
                # hands the builder a path instead -- the value still lives in
                # the .drv, so the recipe hash still covers the whole eval.
                passAsFile = [ "summary" ];
              }
              ''
                mkdir -p $out/share
                cp "$summaryPath" $out/share/report.txt
              '';

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
