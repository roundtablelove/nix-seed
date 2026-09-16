{ inputs, ... }:
{

  perSystem =
    { lib, pkgs, ... }:
    {

      # git and jq are what the scripts under test are made of:
      # write-seed-lock reads records with jq and commits with git, and
      # its tests stand up a real bare remote to push at. HOME because
      # git refuses to run without somewhere to look for a config.
      checks.bats =
        pkgs.runCommand "bats-tests"
          {
            buildInputs = [
              pkgs.bats
              pkgs.git
              pkgs.jq
            ];
          }
          ''
            export HOME=$TMPDIR
            cd ${inputs.self}
            ${lib.getExe pkgs.bats} tests/bin | tee $out
          '';

    };

}
