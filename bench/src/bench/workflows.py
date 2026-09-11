"""Collect step timings of the build-* example workflows, and of
seed-examples (the seed *producer*, DESIGN.md's "slow half" -- distinct
from the build-* workflows, all of which are seed *consumers*), into a
CSV.

One `run` row per completed run (its wall clock), then one row per step
of every `build (<example>, <os>)` / `seed (<example>, <os>)` job of
that run, plus a `job` row with the job's wall clock. Top-level steps
come from the jobs API; the steps inside a composite action (seed
digest, cache pull, mount seed for build-examples; Nix Setup, Cachix
Setup, Build seed for seed-examples) only exist in the job log, as
`##[start-action display=...]` / `##[end-action ...;duration_ms=N]`
markers, so those two workflows' logs are fetched too. Post-job steps
of a composite are prefixed `post `. bin/build-seed also carries its
own `::group::seed: <phase>` markers (eval, build, package, install
oras, push, lock -- the same instrumentation bin/mount-seed uses), so
seed-examples' "Build seed" step gets that further breakdown too.

A build-examples job also gets one `seed size` row, its `bytes` column
holding the seed artifact's compressed size on the wire -- summed from
bin/mount-seed's own parallel-stream download reports in that same log,
so no extra registry call is needed. A build-cache-nix-examples job
gets a `cache size` row the same way, from cache-nix-action's own
restored-archive report -- absent on a cache miss.

Idempotent: runs already in the CSV are skipped, rows are appended per
run, and the command exits early when nothing is new. Logs older than
the retention period are gone; such jobs keep their top-level steps only.

Auth: GH_TOKEN or GITHUB_TOKEN, else `gh auth token`.
"""

from __future__ import annotations

import csv
import fcntl
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import typer

REPO = "roundtablelove/nix-seed"
WORKFLOWS = (
    "build-examples",
    "build-cache-nix-examples",
    "build-raw-examples",
    "seed-examples",
)
API = f"https://api.github.com/repos/{REPO}"
FIELDS = (
    "run_id",
    "workflow",
    "event",
    "created_at",
    "head_sha",
    "job_id",
    "example",
    "os",
    "conclusion",
    "step",
    "seconds",
    "bytes",
)
# build-examples/build-cache-nix-examples/build-raw-examples name their
# matrix jobs "build (<example>, <os>)"; seed-examples names its own
# matrix job "seed (<example>, <os>)" -- same shape, different verb.
JOB_NAME = re.compile(r"^(?:build|seed) \((?P<example>[^,]+), (?P<os>[^)]+)\)$")
START = re.compile(
    r"##\[start-action display=(?P<name>[^;]*);id=(?P<id>[^\]]*)\]"
)
END = re.compile(
    r"##\[end-action id=(?P<id>[^;]*);.*?duration_ms=(?P<ms>\d+)\]"
)
# a mount-seed phase marker or its close, with the line's timestamp
PHASE = re.compile(
    r"^(?P<when>\S+Z) ##\[(?:group\](?P<name>seed: [^\r]*)|endgroup\])"
)
# one of bin/mount-seed's parallel range-fetch streams reporting its own
# downloaded bytes; summed across streams, this is the seed artifact's
# compressed size (store.squashfs or store.dmg.zst -- whichever this run
# fetched), with no separate call to the registry needed.
STREAM = re.compile(r"^\S+Z \S+: (?P<bytes>\d+) B [\d.]+s$", re.MULTILINE)
# nix-community/cache-nix-action (a thin wrapper over actions/cache)
# printing the archive size on a restore; only present on a cache hit,
# same as actions/cache upstream -- a miss has nothing to report yet.
CACHE = re.compile(r"Cache Size: ~[\d.]+ \S+ \((?P<bytes>\d+) B\)")

app = typer.Typer(add_completion=False)


@dataclass(frozen=True)
class Run:
    id: int
    workflow: str
    event: str
    created_at: str
    head_sha: str
    started_at: str | None
    updated_at: str | None


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Surface redirects instead of following them: the log redirect goes
    to blob storage, which must not see the API token."""

    def redirect_request(self, *args: object) -> None:  # noqa: ARG002
        return None


def token() -> str:
    for name in ("GH_TOKEN", "GITHUB_TOKEN"):
        if value := os.environ.get(name):
            return value
    return subprocess.check_output(["gh", "auth", "token"], text=True).strip()


class Client:
    def __init__(self) -> None:
        self.headers = {
            "Authorization": f"Bearer {token()}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        }
        self.opener = urllib.request.build_opener(NoRedirect)

    def get(self, url: str) -> tuple[bytes, str | None]:
        """Return the body and the `next` page URL, if any."""
        request = urllib.request.Request(url, headers=self.headers)
        with self.opener.open(request) as response:
            link = response.headers.get("Link", "")
            nxt = re.search(r'<([^>]+)>; rel="next"', link)
            return response.read(), nxt.group(1) if nxt else None

    def paged(self, url: str, key: str) -> Iterator[dict]:
        nxt: str | None = url
        while nxt:
            body, nxt = self.get(nxt)
            yield from json.loads(body)[key]

    def log(self, job_id: int) -> str:
        """Job log text, or "" when it has expired."""
        request = urllib.request.Request(
            f"{API}/actions/jobs/{job_id}/logs", headers=self.headers
        )
        try:
            self.opener.open(request)
        except urllib.error.HTTPError as error:
            if error.code in (404, 410):
                return ""
            if error.code not in (301, 302, 307):
                raise
            location = error.headers["Location"]
        else:
            raise RuntimeError(f"job {job_id}: log endpoint did not redirect")
        # the blob itself can be gone too (cancelled jobs, expired logs)
        try:
            with urllib.request.urlopen(location) as blob:
                return blob.read().decode(errors="replace")
        except urllib.error.HTTPError as error:
            if error.code in (404, 410):
                return ""
            raise


def seconds(start: str | None, end: str | None) -> float | None:
    if not start or not end:
        return None
    return (timestamp(end) - timestamp(start)).total_seconds()


def timestamp(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def composite_steps(log: str) -> list[tuple[str, float]]:
    """(name, seconds) for each composite action step in a job log."""
    names = {m["id"]: m["name"] for m in START.finditer(log)}
    steps = []
    for m in END.finditer(log):
        name = names.get(m["id"])
        if name is None:
            continue
        if not m["id"].startswith("__self."):
            name = f"post {name}"
        steps.append((name, int(m["ms"]) / 1000))
    return steps


def phase_steps(log: str) -> list[tuple[str, float]]:
    """(name, seconds) for each `::group::seed: <phase>` that bin/mount-seed
    prints, timed from the log's line timestamps to the matching
    `::endgroup::`."""
    steps = []
    opened: tuple[str, datetime] | None = None
    for line in log.splitlines():
        m = PHASE.search(line)
        if m is None:
            continue
        when = timestamp(m["when"])
        if m["name"] is not None:
            opened = (m["name"], when)
        elif opened is not None:
            steps.append((opened[0], (when - opened[1]).total_seconds()))
            opened = None
    return steps


def seed_bytes(log: str) -> int | None:
    """Total bytes bin/mount-seed downloaded for the seed artifact: the
    push is a single OCI blob, fetched as N parallel ranges, so summing
    every stream's own reported byte count gives that blob's size --
    the seed's compressed size on the wire -- with no registry call."""
    matches = list(STREAM.finditer(log))
    if not matches:
        return None
    return sum(int(m["bytes"]) for m in matches)


def cache_bytes(log: str) -> int | None:
    """Compressed size of the actions/cache archive restored, straight
    from cache-nix-action's own report. None on a cache miss, when there
    is nothing to restore yet -- the run's first ever, or a key change."""
    m = CACHE.search(log)
    return int(m["bytes"]) if m else None


def completed_runs(client: Client) -> list[Run]:
    runs = []
    for workflow in WORKFLOWS:
        url = (
            f"{API}/actions/workflows/{workflow}.yaml/runs"
            "?status=completed&per_page=100"
        )
        runs += [
            Run(
                r["id"],
                workflow,
                r["event"],
                r["created_at"],
                r["head_sha"],
                r["run_started_at"],
                r["updated_at"],
            )
            for r in client.paged(url, "workflow_runs")
        ]
    return sorted(runs, key=lambda r: (r.created_at, r.id))


def rows(client: Client, run: Run) -> Iterator[dict[str, object]]:
    # one `run` row per run, whatever its jobs: it is what marks the run
    # as recorded, so a run with no matrix jobs is not refetched forever
    yield {
        "run_id": run.id,
        "workflow": run.workflow,
        "event": run.event,
        "created_at": run.created_at,
        "head_sha": run.head_sha,
        "job_id": "",
        "example": "",
        "os": "",
        "conclusion": "",
        "step": "run",
        "seconds": seconds(run.started_at, run.updated_at),
    }
    url = f"{API}/actions/runs/{run.id}/jobs?per_page=100"
    for job in client.paged(url, "jobs"):
        matched = JOB_NAME.match(job["name"])
        if not matched:
            continue
        base = {
            "run_id": run.id,
            "workflow": run.workflow,
            "event": run.event,
            "created_at": run.created_at,
            "head_sha": run.head_sha,
            "job_id": job["id"],
            "example": matched["example"],
            "os": matched["os"],
            "conclusion": job["conclusion"],
        }
        steps: list[tuple[str, float | None]] = [
            ("job", seconds(job["started_at"], job["completed_at"]))
        ]
        steps += [
            (s["name"], seconds(s["started_at"], s["completed_at"]))
            for s in job["steps"]
        ]
        size = size_step = None
        if run.workflow == "build-examples":
            log = client.log(job["id"])
            steps += composite_steps(log) + phase_steps(log)
            size, size_step = seed_bytes(log), "seed size"
        elif run.workflow == "build-cache-nix-examples":
            size, size_step = cache_bytes(client.log(job["id"])), "cache size"
        elif run.workflow == "seed-examples":
            # the seed/ composite action's own steps (Nix Setup, the
            # optional Cachix Setup, Build seed itself) plus, now that
            # bin/build-seed carries its own `::group::seed: <phase>`
            # markers (the same instrumentation bin/mount-seed uses),
            # a breakdown of what "Build seed" itself is spending time
            # on: eval, build, package (darwin only), install oras,
            # push, lock.
            log = client.log(job["id"])
            steps += composite_steps(log) + phase_steps(log)
        for name, secs in steps:
            yield {**base, "step": name, "seconds": secs}
        if size is not None:
            yield {**base, "step": size_step, "bytes": size}


def recorded(target: Path) -> set[int]:
    if not target.exists():
        return set()
    with target.open(newline="") as f:
        return {int(row["run_id"]) for row in csv.DictReader(f)}


def status(message: str) -> None:
    """Progress on stderr, unbuffered: a full collection takes minutes."""
    print(message, file=sys.stderr, flush=True)


def collect(target: Path) -> None:
    # one collector at a time: two appending the same runs concurrently
    # would record them twice, and `recorded` only reads at the start
    with (target.with_suffix(".lock")).open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        _collect(target)


def _collect(target: Path) -> None:
    client = Client()
    done = recorded(target)
    status(f"{target}: {len(done)} runs recorded; listing completed runs")
    todo = [run for run in completed_runs(client) if run.id not in done]
    if not todo:
        status(f"{target}: up to date ({len(done)} runs)")
        return
    status(f"{target}: {len(todo)} runs to fetch")
    new = not target.exists()
    with target.open("a", newline="") as f:
        writer = csv.DictWriter(f, FIELDS)
        if new:
            writer.writeheader()
        for i, run in enumerate(todo, 1):
            status(
                f"[{i}/{len(todo)}] {run.workflow} {run.id} {run.created_at}"
            )
            writer.writerows(rows(client, run))
            f.flush()
    status(f"{target}: {len(done) + len(todo)} runs recorded")


@app.command()
def main(target: Path = Path("bench/workflows.csv")) -> None:
    """Append the timings of every completed run not yet in TARGET."""
    try:
        collect(target)
    except (urllib.error.HTTPError, subprocess.CalledProcessError) as error:
        print(f"bench-workflows: {error}", file=sys.stderr)
        raise typer.Exit(1) from error


if __name__ == "__main__":
    app()
