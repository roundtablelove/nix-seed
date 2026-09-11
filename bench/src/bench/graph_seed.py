"""Graph seed-examples step by step: one panel per (example, runner),
one stacked bar per commit whose segments are the seed/ composite
action's own steps, in execution order, so the bar is the job and each
segment that step's share of it. This is the seed *producer*
(DESIGN.md's "slow half"), distinct from the build-* workflows graphed
by bench-graph-jobs/bench-graph-self, all of which are seed
*consumers*. Runs of the same commit are one sample, at their median;
nothing is smoothed across commits. The x axis is the sequence of
commits built, in order of first run, labelled only where the commit
touched what the seed producer runs. Successful jobs only, only
examples that still exist under examples/ on runners the workflow's
matrix still lists, and by default only the last 40 commits."""

from __future__ import annotations

import csv
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt
import typer

from bench.common import (
    commit_order,
    commit_ticks,
    configure,
    current_examples,
    matrix_os,
    medians,
    relevant_commits,
    save,
)

configure()

WORKFLOW = "seed-examples"
# the seed/ composite action's own steps, in execution order. bin/
# build-seed carries its own `::group::seed: <phase>` markers (the same
# instrumentation bin/mount-seed uses); where they exist the "Build
# seed" total is dropped so the bar does not count them twice.
STEPS = (
    "Nix Setup",
    "Cachix Setup",
    "Build seed",
    "seed: eval",
    "seed: build",
    "seed: package",
    "seed: install oras",
    "seed: push",
    "seed: lock",
)
PHASES = tuple(s for s in STEPS if s.startswith("seed: "))

app = typer.Typer(add_completion=False)

# (example, os) -> step -> commit ordinal -> seconds of each run
Samples = dict[tuple[str, str], dict[str, dict[int, list[float]]]]


def load(
    source: Path, examples: set[str], runners: set[str]
) -> tuple[list[str], Samples]:
    runs: dict[int, tuple[str, str]] = {}
    rows: list[tuple[int, str, str, str, float]] = []
    with source.open(newline="") as f:
        for row in csv.DictReader(f):
            if row["workflow"] != WORKFLOW:
                continue
            run_id = int(row["run_id"])
            step = row["step"]
            if step == "run":
                runs[run_id] = (row["created_at"], row["head_sha"])
            elif (
                step in STEPS
                and row["conclusion"] == "success"
                and row["seconds"]
                and row["example"] in examples
                and row["os"] in runners
            ):
                rows.append(
                    (
                        run_id,
                        row["example"],
                        row["os"],
                        step,
                        float(row["seconds"]),
                    )
                )
    ordinal = commit_order(runs)
    samples: Samples = defaultdict(
        lambda: defaultdict(lambda: defaultdict(list))
    )
    for run_id, example, os, step, secs in rows:
        _, sha = runs[run_id]
        samples[example, os][step][ordinal[sha]].append(secs)
    for steps in samples.values():
        phased = {x for p in PHASES for x in steps.get(p, {})}
        for x in phased:
            steps.get("Build seed", {}).pop(x, None)
    return list(ordinal), samples


def render(
    source: Path,
    out: Path,
    examples: Path,
    workflows: Path,
    repo: Path,
    last: int,
) -> None:
    runners = matrix_os(workflows, WORKFLOW, job="seed")
    commits, samples = load(source, current_examples(examples), runners)
    labelled = relevant_commits(repo)
    first = max(0, len(commits) - last) if last else 0
    lanes = sorted(samples)
    fig, axes = plt.subplots(
        len(lanes), 1, figsize=(16, 4 * len(lanes)), layout="constrained"
    )
    xs = range(first, len(commits))
    for ax, lane in zip(axes, lanes, strict=True):
        # one bar per commit, one segment per step in execution order:
        # the bar is the job, each segment that step's share of it. the
        # only aggregation is the median across the commit's runs.
        bottom = [0.0] * len(xs)
        for step in STEPS:
            heights = [0.0] * len(xs)
            for x, secs in medians(samples[lane].get(step, {})):
                if x >= first:
                    heights[x - first] = secs
            ax.bar(xs, heights, bottom=bottom, width=0.8, label=step)
            bottom = [b + h for b, h in zip(bottom, heights, strict=True)]
        # the tallest bar sets the axis: every segment is meant to be read
        ax.set_ylim(0, max(bottom))
        commit_ticks(ax, commits, first, labelled)
        example, os = lane
        ax.set_title(
            f"{example} on {os}: seconds per step, stacked; median across "
            "the commit's successful runs"
        )
        ax.set_ylabel("seconds")
        ax.grid(alpha=0.3, axis="y")
        ax.legend(
            title="step",
            fontsize="small",
            loc="upper left",
            bbox_to_anchor=(1, 1),
        )
    fig.suptitle(f"{source.name}: {WORKFLOW}, steps stacked per commit")
    save(fig, out)


@app.command()
def main(
    source: Path = Path("bench/workflows.csv"),
    out: Path = Path("bench/seed.svg"),
    examples: Path = Path("examples"),
    workflows: Path = Path(".github/workflows"),
    repo: Path = Path("."),
    last: int = 40,
) -> None:
    """Graph the seed-examples steps from SOURCE (bench-workflows) into
    OUT, for the examples under EXAMPLES on the runners WORKFLOWS lists,
    the LAST commits (0 for all), labelled where REPO's history says the
    commit could have changed the result."""
    render(source, out, examples, workflows, repo, last)
    print(out)


if __name__ == "__main__":
    app()
