# TODO

- must use signed commits
- look at `dive`
- a seed's `tag` is `self.rev` of the flake that calls `mkSeed`, which in this
  monorepo is the repository's own HEAD: every commit anywhere -- a README typo,
  another example's lock -- gives every example a new tag and forces a full
  re-seed of all of them. Since the lock became atomic that is waste rather than
  corruption, but it is why a cycle is long enough for anything to race it. The
  fix is to tag by a content hash of the example's own inputs, which would also
  make "nothing to commit" the common case rather than the rare one.
- `.seed.lock` records no closure manifest, so the digest is both the fetch
  pointer and the only thing verified. DESIGN.md#closure-manifest wants the
  manifest to be the anchor instead.
- examples enumerate `lib.systems.flakeExposed`, which is wider than the
  systems `mkSeed` supports, so `packages.armv7l-linux.seed` and friends throw
  if forced. Harmless while CI only forces the three real ones; a contributor
  running `nix flake check` on an example may not agree.
- post build the seed updates flake.nix with its commit. Why? so the app build
  can call the right container, ouroboros the seed build is a self-reference in
  the flake

## Flake Parts

- use hercules-ci for promotion, hercules-ci-effects
- review devshell, make-shell
- https://flake.parts/options/mission-control.html
- rust/cargo
- https://flake.parts/options/nix-oci.html
- https://flake.parts/options/pydev.html
- https://github.com/divnix/std

## Funding

- Sovereign Tech Fund
- NLnet Foundation
