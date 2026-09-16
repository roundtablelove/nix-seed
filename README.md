# Nix Seed

> [!WARNING] Work in progress. Does not work as described.

Nix on ephemeral CI.

Source-only change: **build setup \<10s**.

Dependencies via [OCI] layers.

Explicit trust anchors.

> Dependencies realised, once: **$$$**.
>
> Supply chain, secured: **$$$**.
>
> Flow state, uninterrupted: **Priceless**.

Docs:

- [Overview](./OVERVIEW.md) — problems and solutions, plain-English.
- [Design](./DESIGN.md) — full design spec, unavoidably-technical.

______________________________________________________________________

## Platform Support

`x86_64-linux`, `aarch64-linux` and `aarch64-darwin`.

Each platform mounts the seed with the tools it has. Linux uses a squashfs on a
loop device under an overlayfs upper; macOS attaches a compressed disk image
with a `-shadow` file as the writable layer. Neither extracts anything, which
is the point. See [macOS](./DESIGN.md#macos).

Darwin seeds are built on macOS runners, because a Linux host cannot produce
`*-darwin` store paths and the Apple SDK version decides the NAR digest.
`x86_64-darwin` is absent only because `lib.systems.flakeExposed` no longer
lists it.

______________________________________________________________________

## OCI Layers vs `actions/cache`

`actions/cache` operates by:

1. Downloading a monolithic archive.
1. Writing it to disk.
1. Extracting it sequentially.
1. Re-archiving and uploading post-job.

This means:

- High network/disk I/O.
- Serialisation bottlenecks.
- Full dataset copy on every job.
- Poor scaling with cache size.

OCI layers are content-addressed:

- Layer pulls are parallelised.
- Deduplication is automatic.
- Filesystems mount layered content without full extraction.
- Only changed layers are transferred.

Observed characteristics:

- **VM provisioning:** ~5s (fixed provider cost)
- **Layer pull + mount:** \<5s (with runner-local registry, e.g. GHCR)
- **Source fetch:** unchanged
- **Build execution:** unchanged

______________________________________________________________________

## Trust

> **"Just because you're paranoid doesn't mean they aren't after you."**
>
> — Anonymous, c. 1967

Nix Seed provides four trust modes. Choose one.

Quorum-based modes (Credulous and above) require an N-of-M quorum of builders in
independent failure domains (organisational, jurisdictional, infrastructural) to
attest bitwise-identical output. Integrity scales with the quorum threshold (k),
not the builder count (n); adding builders without raising k improves
availability, not security.

______________________________________________________________________

### Trust Level: Innocent

> **"IDGAF about trust. Gimme the Fast!"**
>
> — 99.999% of engineers polled

[Innocent](./DESIGN.md#innocent) anchors trust on the public-good Rekor instance
with a single builder.

- Guarantee: None.
- Attack Surface: Builder, Rekor, and Nix cache infrastructure — all central
  actors.
- Resiliency: Public-good Rekor publishes an availability SLO (not a contractual
  SLA); downtime can block logging and verification when depended on.
- Cost: Free.

______________________________________________________________________

### Trust Level: Credulous

> **"I Want To Believe."**
>
> — Fox Mulder, The X-Files, 1993

[Credulous](./DESIGN.md#credulous) anchors trust on the public-good Rekor
instance with an N-of-M independent builder quorum.

Credulous assumes builders can fail independently, but treats transparency
infrastructure as trusted.

When the configured builder quorum is reached, the master builder creates a
signed git tag on the source commit.

- Guarantee: No single builder can forge a release; compromise requires quorum
  capture.
- Attack Surface: Builder set, master builder, public-good Rekor, OIDC trust
  roots.
- Resiliency: As for [Innocent](#trust-level-innocent).
- Cost: Free.

______________________________________________________________________

### Trust Level: Suspicious

> [!NOTE]
>
> Suspicious is not yet implemented.

> **"Trust, but verify."**
>
> — Ronald Reagan (Russian proverb), 1987

[Suspicious](./DESIGN.md#suspicious) keeps [Credulous](#trust-level-credulous)
builder quorum and adds a K-of-L transparency log quorum, recognising that
transparency infrastructure is itself a potential failure domain.

When quorum is reached, the master builder signs and promotes the release.

- Guarantee: No single builder or single transparency log can unilaterally
  legitimise a release.
- Attack Surface: Builder set, master builder, OIDC trust roots, transparency
  log operators.
- Resiliency: Higher availability than [Credulous](#trust-level-credulous);
  single-log outages are not automatically fatal.
- Cost: Moderate operational overhead for multi-log operation.

______________________________________________________________________

### Trust Level: Zero

> [!NOTE]
>
> Zero is not yet implemented; funding applications are pending.

> **"Ambition must be made to counteract ambition."**
>
> — James Madison, *Federalist No. 51*, 1788
>
> **"Everyone has a plan until they get punched in the mouth."**
>
> — Mike Tyson, 2002

[Zero](./DESIGN.md#zero) assumes that any actor may be compromised or coerced.

Validity is defined by quorum, not by authority.

Bitwise-identical output must be attested across independent failure domains
(separated across organisational, jurisdictional, and infrastructural
boundaries).

Promotion occurs mechanically upon quorum verification. No master builder
exists; promotion is contract-enforced.

Forgery effort compounds with each additional independent failure domain.

Structure constrains power. Verification replaces trust.

- Guarantee: Contract-enforced quorum. Trust is anchored on an Ethereum L2 smart
  contract with an N-of-M independent builder quorum. Backing:
  - **Full-source bootstrap**
  - **Immutable ledger**
  - **Contract-enforced builder independence**
  - **No central actor**
- Attack Surface: Governance keys, misconfiguration,
  [hardware interdiction](./DESIGN.md#hardware-interdiction).
- Resiliency: High.
- Cost (3 builders, 4 systems): ~Ξ0.002 per promotion event (±50% depending on
  L2 gas conditions) (~$6 @ Ξ1=$3k).

## Quickstart / Evaluation

Add `nix-seed` to your `flake.nix` and expose `seed` in `packages`:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nix-seed = {
      url = "github:roundtablelove/nix-seed";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = inputs: {
    packages =
      inputs.nixpkgs.lib.genAttrs inputs.nixpkgs.lib.systems.flakeExposed (
        system:
        let
          pkgs = inputs.nixpkgs.legacyPackages.${system};
        in
        {
          # placeholder: replace
          default = pkgs.hello;
          seed = inputs.nix-seed.lib.mkSeed {
            inherit pkgs;
            inherit (inputs) self;
          };
        }
      );
  };
}
```

> [!NOTE]
>
> The examples below are GitHub-specific. The approach applies to any CI.
>
> Seed and project builds require `id-token: write` permission.
>
> If outputs include an OCI image, like seed build, the `packages: write`
> permission is required.

> [!WARNING]
>
> Untrusted pull requests that modify `flake.lock` **MUST NOT** trigger seed or
> project builds.

### .github/workflows/seed.yaml

Two jobs, not one. Each matrix leg publishes its own system's seed and records
the digest; a single `lock` job then commits every system's digest to
`.seed.lock` together. A leg cannot write the lock itself, because it only ever
knows its own system — one that tried would leave the lock naming a single
system for as long as its siblings took to finish, and anything reading the
lock in that window would find its own system missing.

`needs.seed.result` on a matrix job is the aggregate, so the `if` below is the
whole rule: if any system fails to publish, no lock is written and the lock
stays on the previous revision.

```yaml
name: seed

on:
  push:
    branches:
      - master
    paths:
      - flake.lock
  workflow_dispatch:

# one publishing cycle at a time: two overlapping cycles carry different
# revisions, and each would write its own over the other's
concurrency:
  group: seed-${{ github.ref }}
  cancel-in-progress: true

jobs:
  seed:
    permissions:
      contents: read
      id-token: write
      packages: write
    strategy:
      # every system reports its own failure in one run; the lock is
      # still all-or-nothing, because the job below simply will not run
      fail-fast: false
      matrix:
        os:
          - ubuntu-22.04
          - ubuntu-22.04-arm
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v6
      - uses: roundtablelove/nix-seed/seed
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}

  lock:
    needs: seed
    if: ${{ needs.seed.result == 'success' }}
    runs-on: ubuntu-latest
    permissions:
      # the only job that commits
      contents: write
    steps:
      - uses: actions/checkout@v6
      - uses: roundtablelove/nix-seed/seed/lock
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
```

### .github/workflows/build.yaml

A plain checkout takes the branch tip, which after a seed cycle is the `lock`
job's commit — the one naming the seeds that cycle just published. That is
what you want to build. Note that it is *not* the commit that triggered
seeding: neither `github.sha` nor the triggering run's `head_sha` names it,
since both are that commit's parent. If you need the lock commit exactly
rather than the tip, `seed/lock` publishes its sha as a `seed-lock-commit`
artifact — see this repository's own `build-examples.yaml`.

```yaml
on:
  push:
    branches:
      - master
    paths-ignore:
      - flake.lock
  workflow_run:
    workflows:
      - seed
    types:
      - completed
jobs:
  build:
    if: ${{ github.event_name == 'push' || github.event.workflow_run.conclusion == 'success' }}
    permissions:
      contents: read
      id-token: write
    strategy:
      matrix:
        os:
          - ubuntu-22.04
          - ubuntu-22.04-arm
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v6
      # setup only: mounts the seed as /nix/store, hands it to the runner
      # user, and puts the seeded nix on PATH
      - uses: roundtablelove/nix-seed@v1
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          cachix_cache: <name>
          cachix_auth_token: ${{ secrets.CACHIX_AUTH_TOKEN }}
      # your build, however you like it. no sudo, no wrapper: the baked
      # nix.conf carries no substituters, so this reaches nothing but the
      # mounted closure. add `unshare --net` to enforce that rather than
      # configure it.
      - run: nix build --print-build-logs
```

## Production Configuration

> [!WARNING]
>
> The [Design](./DESIGN.md) document contains critical security information.
>
> Read it. Twice. Or, get pwned.

Update `seedCfg` to use a quorum-based posture and define builders:

```nix
seedCfg = {
  trust = "credulous";
  builders = {
    github.master = true;
    gitlab = {};
    scaleway = {};
  };
  quorum = 2;
};
```

Builder independence requirements are detailed in
[Threat Actors](./DESIGN.md#threat-actors).

### Builder Repository Sync

`nix-seed` includes a helper to initialise and configure builder repositories to
mirror the source repository.

Provider credentials must be present in the environment.

```sh
nix run github:roundtablelove/nix-seed/v1#sync
```

[oci]: https://opencontainers.org/
