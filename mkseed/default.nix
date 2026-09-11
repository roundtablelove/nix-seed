let

  # resolves one seedOutputs entry ("<type>.<name>") against a flake's
  # outputs. split on the FIRST "." only, so a name containing dots
  # still resolves correctly. apps carry an optional `.package`
  # passthru (the app itself is `{ type = "app"; program = "..."; }`,
  # never a derivation); every other type is looked up directly. may
  # throw (missing attribute, wrong type, ...) -- callers that need to
  # survive a bad entry wrap this in tryWarn themselves.
  resolveOutput =
    pkgs: self: system: entry:
    let
      inherit (pkgs) lib;
      parts = lib.splitString "." entry;
      type = builtins.head parts;
      outName = lib.concatStringsSep "." (builtins.tail parts);
      output = self.${type}.${system}.${outName};
    in
    if type == "apps" then output.package or null else output;

in
{
  pkgs,
  self,
  # dotted "<type>.<name>" flake output paths to bake, e.g.
  # "packages.default", "devShells.msrv", "checks.bats". <type> is one
  # of apps/checks/devShells/packages, resolved as
  # self.<type>.<system>.<name> -- see resolveOutput above. nothing
  # here auto-discovers flake outputs, so an output the caller doesn't
  # list is simply never looked up, and never forced: unlike the old
  # auto-scan-plus-filter, there is no way to be surprised by an
  # unwanted output evaluating at all.
  seedOutputs ? [ "packages.default" ],
  # name from the first seedOutputs entry
  name ?
    let
      package = resolveOutput pkgs self pkgs.stdenv.hostPlatform.system (builtins.head seedOutputs);
    in
    "${package.pname or package.name or "unnamed"}.seed",
  tag ? self.rev or self.dirtyRev or null,
  nix ? pkgs.nixVersions.latest,
  # packages whose bin/ (and share/, etc.) are unioned into a buildEnv,
  # baked into the seed and reachable at .seed/env -- a single dir with
  # bin/ for the runner's PATH and etc/nix.conf for the build config.
  # its symlinks point into /nix/store, resolved once the seed is
  # mounted. defaults to just nix. NOTE: keep this a curated tool list,
  # not the whole closure -- buildEnv collides on duplicate paths and
  # the closure (already at /nix/store) is full of build-only deps.
  pathPackages ? [ nix ],
  nixConf ? "",
  # squashfs zstd level. 15 is squashfs's default and the knee of the
  # curve: ~3x faster to build than 19 for ~1% more size. drop toward
  # 9 to trade image size for a much faster seed build; the consumer
  # restores from the in-datacenter cache where size barely matters.
  compressionLevel ? 9,
  # flake inputs (by name, at any depth) whose source is NOT baked
  # into the seed. removeAttrs also stops the collect recursion into
  # them, dropping their whole subtree (e.g. emanote's haskell
  # closure). empty by default -- nix-seed's own dev/docs/CI tooling
  # names aren't meaningful to a generic consumer; see
  # modules/packages.nix for nix-seed's own list.
  excludeInputs ? [ ],
  ...
}:
let

  inherit (pkgs) lib stdenv;
  inherit (stdenv.hostPlatform) system;

  # tryEval with a warning + fallback on throw. Catches assert/throw
  # only; an output failing with a builtin type error (which tryEval
  # cannot catch, e.g. emanote's docs, which throws from toJSON over a
  # functor) must simply not be named in seedOutputs -- nothing here
  # auto-discovers outputs, so an unlisted one is never forced at all.
  tryWarn =
    msg: fallback: x:
    let
      r = builtins.tryEval x;
    in
    if r.success then r.value else lib.warn "mkSeed: ${msg}" fallback;

  # a buildEnv unioning pathPackages' bin/ plus nix.conf at etc/nix.conf,
  # baked into the seed and exposed at .seed/env: .seed/env/bin for PATH,
  # .seed/env/etc/nix.conf for the offline build config.
  pathEnv = pkgs.buildEnv {
    name = "${name}-env";
    paths = pathPackages ++ [
      (pkgs.writeTextDir "etc/nix/nix.conf" ''
        experimental-features = nix-command flakes
        build-users-group =
        sandbox = false
        substitute = false
        fallback = false
        substituters =
        trusted-substituters =
        builders =
        flake-registry =
        connect-timeout = 1
        download-attempts = 1
        show-trace = true
        eval-cache = false
        # upstream default is max-jobs = 1, which serializes independent
        # derivations; the runner is dedicated, so use every core.
        max-jobs = auto
        cores = 0
        # ephemeral CI store: skipping sqlite fsyncs speeds --load-db
        # and post-build registration; durability is worthless here.
        fsync-metadata = false
        ${nixConf}
      '')
    ];
  };

  # every store path the seed must contain, as closureInfo rootPaths:
  #   - nix itself: the consumer runs it from the mounted store.
  #   - pathEnv: the buildEnv exposed at .seed/env (bin/ + etc/nix.conf).
  #   - stdenv and stdenvNoCC: `inputDerivation` (below) deliberately
  #     never sources `$stdenv/setup` -- nixpkgs' own comment on it is
  #     "does not use setup.sh or stdenv, to keep the env most pristine"
  #     -- so neither's store path ever appears in what it captures.
  #     `nix build` never notices, since a package whose output is
  #     already registered valid skips its builder (and so setup.sh)
  #     entirely; `nix develop` always re-runs part of the build to
  #     construct the interactive environment, which does source it.
  #     both variants are needed: a devShell pulling in a prebuilt
  #     toolchain (e.g. rust-overlay, which unpacks rather than
  #     compiles) is built with stdenvNoCC, a genuinely different
  #     derivation from stdenv, not merely stdenv without a compiler
  #     attached later -- confirmed by finding nix develop, offline,
  #     rebuilding stdenvNoCC's *own* recipe from bootstrap-tools up
  #     when it alone was missing.
  #   - bashInteractive: nix develop always needs a real, readline-
  #     capable bash to build its interactive environment against,
  #     regardless of what any devShell declares -- this is nix's own
  #     choice, not the flake's, so nothing a consumer's flake exposes
  #     ever references it and no other rule here would catch it.
  #     confirmed the same way as stdenv/stdenvNoCC and libiconv above:
  #     nix develop, offline, rebuilding it from its own recipe
  #     (gettext, perl, bison, m4, readline -- and so bootstrap-tools up
  #     to build *them*) when it alone was missing.
  #   - every flake input source, recursively -> offline flake
  #     *evaluation* (nix reads each locked input from the store).
  #   - each output's inputDerivation -> its full build-input closure,
  #     so the build runs offline without rebuilding the rest of the
  #     toolchain (rustc, glibc, ...).
  #   - every declared output of every output's direct build inputs,
  #     not just whichever one inputDerivation happened to capture: a
  #     bare `buildInputs = [ foo ]` expands to foo's "out" *and* "dev"
  #     via stdenv's multiple-outputs.sh setup hook, but inputDerivation
  #     never sources setup.sh (see above), so a second output picked up
  #     only through that hook -- e.g. libiconv's "dev", on a devShell
  #     compiling against it -- is invisible to it. confirmed the same
  #     way as stdenvNoCC: nix develop, offline, rebuilding libiconv
  #     from its own recipe (bootstrap-stage2-stdenv-darwin up) when
  #     just its "dev" output alone was missing.
  # the derivations named by seedOutputs. isDerivation reads only
  # `.type` (cheap); the isNixSeed guard drops a nested seed before its
  # inputDerivation is taken (which would recurse into this seed's own
  # closure). a seedOutputs entry that doesn't resolve (missing
  # attribute, bad "<type>", ...) or throws while it or the checks
  # above force it is skipped, with a warning naming it, rather than
  # failing the whole build.
  harvested = lib.filter (drv: drv != null) (
    map
      (
        entry:
        tryWarn "skipping seedOutputs entry \"${entry}\" (missing, or threw while resolving)" null (
          let
            drv = resolveOutput pkgs self system entry;
          in
          if lib.isDerivation drv && !drv ? isNixSeed then drv else null
        )
      )
      seedOutputs
  );
  buildTimeRoots = lib.concatMap
    (
      drv:
      tryWarn "no build inputs for a flake output (threw)" [ ] (
        lib.concatMap (
          input: if lib.isDerivation input then map (o: input.${o}) (input.outputs or [ "out" ]) else [ input ]
        ) (
          lib.concatMap (attr: drv.${attr} or [ ]) [
            "buildInputs"
            "nativeBuildInputs"
            "propagatedBuildInputs"
            "propagatedNativeBuildInputs"
          ]
        )
      )
    )
    harvested;
  closure = pkgs.closureInfo {
    rootPaths = [
      nix
      pathEnv
      stdenv
      pkgs.stdenvNoCC
      pkgs.bashInteractive
    ]
    ++ (
      let
        collect =
          flake:
          lib.concatMap (i: [ i ] ++ collect i) (
            lib.attrValues (removeAttrs (flake.inputs or { }) excludeInputs)
          );
      in
      map (i: i.outPath) (collect self)
    )
    ++ lib.filter (p: p != null) (
      map
        (
          drv:
          tryWarn "no build closure for a flake output (threw)" null (
            drv.inputDerivation or drv
          )
        )
        harvested
    )
    ++ buildTimeRoots;
  };

  # the seed: a squashfs of the build closure the consumer mounts as
  # /nix/store (store paths sit at the fs root, basename = store
  # hash-name). under .seed/ (so the squashfs is the seed's only
  # artifact) it also carries `registration` (to re-populate a fresh
  # nix db offline, marking the baked paths valid) and an `env` symlink
  # into the baked buildEnv (env/bin for PATH, env/etc/nix.conf for the
  # build config). the consumer reads them from the read-only mount.
  # mounting is O(1); reads decompress lazily, so there is no per-file
  # extraction. see DESIGN.md#delivery.
  # what the consumer will fetch, per platform. bin/build-seed reads
  # both from passthru rather than hard-coding a filename.
  format = if stdenv.hostPlatform.isDarwin then "dmg" else "squashfs";
  # the dmg is uncompressed -- attach and every read go through the
  # codec otherwise, see DESIGN.md#macos -- and travels under zstd.
  artifact = if format == "dmg" then "store.dmg.zst" else "store.squashfs";

  passthru = {
    inherit
      name
      tag
      pathEnv
      format
      artifact
      ;
    # marker so a seed harvesting self.packages skips a nested seed
    # (its inputDerivation would recurse into this closure).
    isNixSeed = true;
  };

in
# every other platform: the consumer has no way to mount the artifact,
# so fail here rather than producing a seed nothing can run.
# see DESIGN.md#constraints.
lib.throwIf (!stdenv.hostPlatform.isLinux && !stdenv.hostPlatform.isDarwin)
  ''
    mkSeed: unsupported system "${system}". nix-seed supports linux and
    darwin; see DESIGN.md#constraints and DESIGN.md#macos.
  ''
  (
    if stdenv.hostPlatform.isDarwin then
      # darwin: the image is a .dmg assembled by hdiutil, which needs
      # diskarbitrationd and so cannot run inside the nix sandbox. this
      # derivation therefore produces the image's *inputs*, and
      # bin/build-seed calls bin/make-dmg on them outside the sandbox.
      # everything here still comes from closureInfo, so what goes into
      # the image is determined by the evaluation exactly as on linux --
      # only the packaging step escapes. see DESIGN.md#macos.
      pkgs.runCommand name { inherit passthru; } ''
        mkdir $out
        cp ${closure}/store-paths $out/store-paths
        cp ${closure}/registration $out/registration
        # total-nar-size sizes the sparse image make-dmg creates
        cp ${closure}/total-nar-size $out/nar-size
        ln -s ${pathEnv} $out/env
      ''
    else
      pkgs.runCommand name
        {
          inherit passthru;
          nativeBuildInputs = [ pkgs.squashfsTools ];
        }
        ''
          mkdir $out
          # timestamps come from SOURCE_DATE_EPOCH (set by nix) for a
          # reproducible image; passing -*-time here would conflict.
          # registration + env go under .seed/ as pseudo-entries so the
          # squashfs is the only output. mksquashfs clamps pseudo mtimes to
          # SOURCE_DATE_EPOCH too, so the image stays reproducible.
          # .seed/env -> the baked buildEnv, resolved through the mounted
          # store; the consumer adds /nix/.ro-store/.seed/env/bin to PATH
          # and reads /nix/.ro-store/.seed/env/etc/nix.conf.
          mksquashfs $(cat ${closure}/store-paths) $out/${artifact} \
            -keep-as-directory -all-root -no-hardlinks \
            -comp zstd -Xcompression-level ${toString compressionLevel} \
            -p '.seed d 555 0 0' \
            -p ".seed/registration f 444 0 0 cat ${closure}/registration" \
            -p ".seed/env s 777 0 0 ${pathEnv}"
        ''
  )
