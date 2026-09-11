{ self, ... }:
{

  perSystem =
    { lib, pkgs, ... }:
    {

      packages =
        let
          name = "nix-seed";
          seed = self.lib.mkSeed {
            inherit name pkgs self;
            # our own devShell and bats check -- deliberately excludes
            # this seed itself (avoids circularity) and emanote's
            # docs/github-io (fail to evaluate) by simply never naming
            # them; see mkseed/default.nix's seedOutputs comment.
            seedOutputs = [
              "devShells.default"
              "checks.bats"
            ];
            # our own dev/docs/CI tooling, never needed to build a
            # consumer's project (see mkseed/default.nix's comment).
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
            # no rev when using `nix build path:.`
            tag = self.rev or self.dirtyRev or null;
          };
        in
        # linux and darwin have delivery mechanisms; nothing else does, and
        # mkSeed throws there (DESIGN.md#constraints). guarding here keeps
        # the flake evaluating on those systems, so the devshell and docs
        # stay usable.
        lib.optionalAttrs
          (pkgs.stdenv.hostPlatform.isLinux || pkgs.stdenv.hostPlatform.isDarwin)
          {
            default = seed;
            inherit seed;
          };

    };

}
