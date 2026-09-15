{ inputs, ... }: {

  imports = [ inputs.devshell.flakeModule ];

  perSystem = { lib, pkgs, ... }: {

    devshells.default = {
      packages =
        with pkgs;
        [
          cosign
          oras
          # bench/: the dependencies bench/pyproject.toml declares; keep
          # both in step
          (python3.withPackages (p: [
            p.matplotlib
            p.pyyaml
            p.typer
          ]))
        ]
        # squashfs is the linux delivery format; darwin ships a disk image
        # built with hdiutil, a system binary rather than a nixpkgs one.
        # see DESIGN.md#delivery.
        ++ lib.optionals stdenv.hostPlatform.isLinux [ squashfsTools ];

      # the bench package runs from its source tree, so edits need no
      # reinstall; the commands mirror pyproject's [project.scripts]
      env = [
        {
          name = "PYTHONPATH";
          eval = "$PRJ_ROOT/bench/src";
        }
      ];
      commands = [
        {
          name = "bench-workflows";
          command = ''python -m bench.workflows "$@"'';
          help = "collect build-* workflow timings into bench/workflows.csv";
        }
        {
          name = "bench-stats";
          command = ''python -m bench.stats "$@"'';
          help = "spread of a step's timings, to size a change against the noise";
        }
        {
          name = "bench-graph-jobs";
          command = ''python -m bench.graph_jobs "$@"'';
          help = "graph job wall clock from bench/workflows.csv";
        }
        {
          name = "bench-graph-self";
          command = ''python -m bench.graph_self "$@"'';
          help = "graph build-examples step times from bench/workflows.csv";
        }
        {
          name = "bench-graph-size";
          command = ''python -m bench.graph_size "$@"'';
          help = "graph seed vs cache artifact size from bench/workflows.csv";
        }
        {
          name = "bench-graph-seed";
          command = ''python -m bench.graph_seed "$@"'';
          help = "graph seed-examples (the seed producer) step times";
        }
      ];
    };

  };

}
