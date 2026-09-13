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
      package = resolveOutput pkgs self pkgs.stdenv.hostPlatform.system (
        builtins.head seedOutputs
      );
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
  # zstd level: squashfs's compression on linux, the transport wrapper
  # around the uncompressed image on darwin. 15 is squashfs's default and
  # the knee of the curve: ~3x faster to build than 19 for ~1% more size.
  # drop toward 9 to trade image size for a much faster seed build; the
  # consumer restores from the in-datacenter cache where size barely
  # matters.
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
        cores = 0
        max-jobs = auto
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
  #   - stdenv and stdenvNoCC, but only when seedOutputs names a
  #     devShell: an ordinary package or check's own inputDerivation
  #     already references whichever variant it was built with (nix
  #     sets it as a plain, unconditional env var, independent of
  #     whether the builder ever sources $stdenv/setup -- confirmed via
  #     `nix path-info`, which lists e.g. stdenv-linux-no-cc as a real
  #     reference of a plain runCommand's inputDerivation), so
  #     closureInfo already bakes it transitively there. what that
  #     never covers is `nix develop` itself: it always re-runs part of
  #     the build to construct its interactive environment, sourcing
  #     $stdenv/setup for real, and a devShell pulling in a prebuilt
  #     toolchain (e.g. rust-overlay, which unpacks rather than
  #     compiles) is built with stdenvNoCC, a genuinely different
  #     derivation from stdenv, not merely stdenv without a compiler
  #     attached later -- confirmed by finding nix develop, offline,
  #     rebuilding stdenvNoCC's *own* recipe from bootstrap-tools up
  #     when it alone was missing. a devShell's own inputDerivation
  #     cannot be trusted to already carry the reference the way a
  #     package's does, either: a plain pkgs.mkShell is stdenv.
  #     mkDerivation underneath and does capture it, but numtide/
  #     devshell (this repo's own devShells.default) is not -- it has
  #     no `inputDerivation` attribute at all, so harvesting falls back
  #     to the devshell derivation itself, whose entire real closure is
  #     one internal symlink dir (confirmed via `nix path-info` on its
  #     actual build output: no stdenv, no bash, nothing) because the
  #     real environment is assembled by direnv/the devshell CLI at
  #     `nix develop` time, never baked into any derivation ahead of
  #     it. so both are included whenever a devShell is being baked
  #     (nix develop may run against it, on any framework) and dropped
  #     otherwise (verified: examples/{rust,python,curl,eval-heavy},
  #     all packages-only with no devShell in sight and eval-heavy's
  #     default itself stdenvNoCC-built via runCommand, all build
  #     offline without either baked).
  #   - bashInteractive, same condition: nix develop always needs a
  #     real, readline-capable bash to build its interactive
  #     environment against, regardless of what any devShell declares
  #     -- this is nix's own choice, not the flake's, so nothing a
  #     consumer's flake exposes ever references it and no other rule
  #     here would catch it. confirmed directly: even a plain mkShell's
  #     own inputDerivation only ever references plain, non-interactive
  #     bash (nix's own builder interpreter, present on every
  #     derivation) -- a completely different package from
  #     bashInteractive -- and confirmed the same way as stdenv/
  #     stdenvNoCC and libiconv above: nix develop, offline, rebuilding
  #     it from its own recipe (gettext, perl, bison, m4, readline --
  #     and so bootstrap-tools up to build *them*) when it alone was
  #     missing.
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
    map (
      entry:
      tryWarn
        "skipping seedOutputs entry \"${entry}\" (missing, or threw while resolving)"
        null
        (
          let
            drv = resolveOutput pkgs self system entry;
          in
          if lib.isDerivation drv && !drv ? isNixSeed then drv else null
        )
    ) seedOutputs
  );
  buildTimeRoots = lib.concatMap (
    drv:
    tryWarn "no build inputs for a flake output (threw)" [ ] (
      lib.concatMap
        (
          input:
          if lib.isDerivation input then
            map (o: input.${o}) (input.outputs or [ "out" ])
          else
            [ input ]
        )
        (
          lib.concatMap (attr: drv.${attr} or [ ]) [
            "buildInputs"
            "nativeBuildInputs"
            "propagatedBuildInputs"
            "propagatedNativeBuildInputs"
          ]
        )
    )
  ) harvested;
  closure = pkgs.closureInfo {
    rootPaths = [
      nix
      pathEnv
    ]
    ++ lib.optionals (lib.any (lib.hasPrefix "devShells.") seedOutputs) [
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
      map (
        drv:
        tryWarn "no build closure for a flake output (threw)" null (
          drv.inputDerivation or drv
        )
      ) harvested
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
  # extraction. see DESIGN.md#delivery. the linux/darwin split
  # (squashfs vs uncompressed dmg.zst) is determined by the system at
  # build time and is now bin/build-seed's concern, not exposed via
  # passthru.

  passthru = {
    inherit
      name
      tag
      pathEnv
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
      # darwin: the image is a .dmg written by hdiutil, which talks to
      # diskarbitrationd and the DiskImages helper -- mach services the
      # sandbox denies. the escape is *declared* rather than scripted
      # around: __noChroot drops the sandbox for this derivation alone
      # (and only where the builder sets `sandbox = relaxed`, which
      # seed/action.yaml does on macOS), so the image stays a derivation
      # output determined by closureInfo exactly as the squashfs is.
      #
      # the image is uncompressed (UDRO) inside a zstd stream that the
      # consumer decodes once before attaching. a compressed UDIF image
      # (lzfse or lzma) pays the codec on every read instead: attaching
      # rust's lzfse image took 22-28s in every round against 6-11s for
      # python's larger one, because attach walks the volume's metadata
      # and the cost tracks inodes rather than bytes; evaluation off the
      # mounted image then varied 5-9x run to run. uncompressed, attach
      # is 1-5s and evaluation sits in a 1.5s band. see DESIGN.md#macos.
      #
      # the output is not byte-reproducible (hdiutil stamps a volume
      # UUID and creation time), which is why .seed.lock anchors on the
      # closure manifest and treats the image digest as a fetch pointer
      # only. see DESIGN.md#closure-manifest.
      pkgs.runCommand name
        {
          inherit passthru;
          # hdiutil is /usr/bin/hdiutil, a host binary with no nixpkgs
          # equivalent -- the one implicit host dependency, and the
          # reason __noChroot is here at all. everything else is
          # declared: pax builds the farm, zstd wraps the image.
          __noChroot = true;
          nativeBuildInputs = [
            pkgs.pax
            pkgs.zstd
          ];
        }
        ''
          mkdir $out

          # the image is built from a hardlink farm handed to hdiutil,
          # rather than by copying store paths into a mounted volume.
          # copying through the mount serialises on HFS+'s single
          # catalog B-tree lock: that is why four concurrent dittos came
          # out *slower* than one on the largest closure (rust 276s
          # against a 175s serial baseline) while helping the small ones
          # (eval-heavy 34s, curl 56s). handing hdiutil a folder lets it
          # write the filesystem image directly, so the mount, the copy
          # and the sparse-to-UDRO convert all disappear, and the farm
          # itself moves metadata only.
          #
          # the farm must sit on the same filesystem as the store: the
          # installer gives /nix its own APFS volume, so linking out of
          # /nix/store into a build directory under /private/tmp would
          # cross devices and fail with EXDEV. that is what the builder's
          # `build-dir` setting is for -- seed/action.yaml points it at a
          # directory on the /nix volume, and this is where that matters.
          farm=$TMPDIR/farm
          mkdir -p $farm/store $farm/.seed

          # /nix/var is a symlink to a fixed path outside the image, not
          # a directory inside it: mount-seed attaches the whole image at
          # /nix (the synthetic mountpoint accepts nothing else -- a
          # subdirectory cannot be pre-created there to attach the store
          # alone), so anything actually stored under /nix/var would sit
          # behind the -shadow copy-on-write file like the rest of the
          # volume. the symlink's target is real disk instead, created by
          # mount-seed before attach; nix follows it transparently.
          ln -s /private/var/nix-seed $farm/var

          # hardlink every store path into the farm. in copy mode pax
          # reads the names to act on from stdin, and -l links regular
          # files instead of copying them, so this costs metadata only.
          # feed it bare basenames from inside the store: pax recreates
          # whatever path it is handed, so an absolute one would nest
          # each tree under its own full path.
          while IFS= read -r p; do printf '%s\n' "''${p##*/}"; done \
            <${closure}/store-paths >$TMPDIR/names
          ( cd /nix/store && pax -rw -l <$TMPDIR/names $farm/store/ )

          cp ${closure}/registration $farm/.seed/registration
          # an absolute symlink into the store, resolved once the image
          # is attached at /nix -- the same contract as the squashfs
          # pseudo-entry.
          ln -s ${pathEnv} $farm/.seed/env

          # one pass: hdiutil sizes the image from the folder and writes
          # it read-only. a case-sensitive filesystem is mandatory -- the
          # store holds paths that differ only in case, and APFS defaults
          # to case-insensitive. HFS+ rather than APFS: `hdiutil attach`'s
          # cost tracks file count, not bytes, and HFS+'s flat catalog
          # B-tree is lighter per file to walk on attach than APFS's
          # copy-on-write object map -- six rounds each way measured
          # attach dropping from 4-5s to about 1.2-1.3s on both examples.
          /usr/bin/hdiutil create -srcfolder $farm \
            -fs 'Case-sensitive Journaled HFS+' -volname NixSeed \
            -format UDRO -o $TMPDIR/store.dmg

          # every directory in the farm inherited the store's read-only
          # mode, and unlinking an entry needs write permission on its
          # *parent*, so the tree has to be made writable before nix can
          # remove the build directory it sits in.
          chmod -R u+w $farm

          # zstd for transport only: the registry blob and the cache
          # entry would otherwise carry 3-4 GB of raw blocks. -T0 uses
          # every core.
          zstd -T0 -${toString compressionLevel} --quiet \
            $TMPDIR/store.dmg -o $out/store.dmg.zst
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
          mksquashfs $(cat ${closure}/store-paths) $out/store.squashfs \
            -keep-as-directory -all-root -no-hardlinks \
            -comp zstd -Xcompression-level ${toString compressionLevel} \
            -p '.seed d 555 0 0' \
            -p ".seed/registration f 444 0 0 cat ${closure}/registration" \
            -p ".seed/env s 777 0 0 ${pathEnv}"
        ''
  )
