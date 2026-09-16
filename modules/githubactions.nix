{ inputs, ... }:
{

  imports = [ inputs.github-actions-nix.flakeModule ];

  # NOTE: this definition is stale and generates nothing that runs --
  # the workflows CI actually uses are the checked-in ones under
  # .github/workflows/. It describes a single job calling ./seed, which
  # since the lock became atomic is only half a cycle: publishing a seed
  # now also needs a ./seed/lock job to record the digests. Do not take
  # the shape below as the reference; see .github/workflows/
  # seed-examples.yaml, or the two-job example in README.md.
  flake.githubActions = {

    enable = true;

    workflows.seed = {

      name = "Seed";

      on = {
        push = { };
        pullRequest = { };
      };

      jobs = {

        build = {
          runsOn = "ubuntu-latest";
          permissions = {
            # allow checkout and other read-only ops; this is the default
            # but specifying a permissions block drops defaults back to
            # `none`
            contents = "read";
            # minting an OIDC token lets COSIGN_EXPERIMENTAL=1 keep cosign
            # signing non-interactive instead of invoking the device flow.
            id-token = "write";
            # allow push to registry
            packages = "write";
          };
          steps = [
            {
              name = "Checkout";
              uses = "actions/checkout@v6";
            }
            {
              name = "Build Seed";
              uses = "./seed";
              "with".github_token = "$${{ secrets.GITHUB_TOKEN }}";
            }
          ];
        };

      };

    };

  };

}
