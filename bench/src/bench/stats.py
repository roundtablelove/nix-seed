"""Report a step's timings as a distribution rather than a number, and
say where one run sits inside it.

The graph commands plot trends; this one answers the question that
precedes any optimisation: is the difference I am looking at bigger than
the noise? On the hosted macOS runners it usually is not -- the same
step on the same example has been observed to vary 2.7-3.6x run to run,
so a single fast run and a single slow one can differ by more than any
plausible change to what the step does. Comparing one run against one
earlier run, the obvious thing to do, therefore reads pure scheduling
luck as a speedup or a regression.

`--run` is the guard against that: it places a run's value in the
history's percentile and refuses to call anything evidence unless it
falls outside the range already observed without any change at all.
"""

from __future__ import annotations

import csv
from collections import defaultdict
from pathlib import Path
from statistics import median

import typer

app = typer.Typer(add_completion=False)

# a value at or inside these percentiles of the historical range is
# indistinguishable from an ordinary lucky or unlucky run
LUCKY = 10.0
UNLUCKY = 90.0

# (example, os) -> seconds of every successful run
Samples = dict[tuple[str, str], list[float]]


def load(
    source: Path, workflow: str, step: str
) -> tuple[Samples, dict[int, Samples]]:
    """Every successful sample of STEP, and the same split per run id so
    one run can be located within the whole."""
    whole: Samples = defaultdict(list)
    per_run: dict[int, Samples] = defaultdict(lambda: defaultdict(list))
    with source.open(newline="") as f:
        for row in csv.DictReader(f):
            if (
                row["workflow"] != workflow
                or row["step"] != step
                or row["conclusion"] != "success"
                or not row["seconds"]
            ):
                continue
            lane = (row["example"], row["os"])
            secs = float(row["seconds"])
            whole[lane].append(secs)
            per_run[int(row["run_id"])][lane].append(secs)
    return whole, per_run


def percentile(values: list[float], value: float) -> float:
    """Share of VALUES strictly below VALUE, as a percentage."""
    return 100.0 * sum(v < value for v in values) / len(values)


def verdict(values: list[float], value: float) -> str:
    """What a run's value is worth as evidence. Inside the range seen
    without any change, it is worth nothing whichever end it sits at --
    naming both ends matters, because a value at the fast end is exactly
    the one somebody is tempted to report as a win."""
    if value < min(values):
        return "faster than anything yet seen"
    if value > max(values):
        return "slower than anything yet seen"
    p = percentile(values, value)
    if p <= LUCKY:
        return "near the fastest seen - not evidence of a win"
    if p >= UNLUCKY:
        return "near the slowest seen - not evidence of a regression"
    return "typical - within noise"


def widths(lanes: list[tuple[str, str]]) -> tuple[int, int]:
    """Example and runner names vary enough in length (rust-ripgrep,
    ubuntu-22.04-arm) that fixed columns either collide or waste space."""
    return (
        max(len(e) for e, _ in lanes) + 2,
        max(len(o) for _, o in lanes) + 2,
    )


def report(whole: Samples) -> None:
    ew, ow = widths(list(whole))
    print(
        f"{'example':<{ew}}{'os':<{ow}}{'n':>4}{'min':>9}{'med':>9}"
        f"{'max':>9}{'spread':>9}"
    )
    for (example, os), values in sorted(whole.items()):
        lo, hi = min(values), max(values)
        print(
            f"{example:<{ew}}{os:<{ow}}{len(values):>4}{lo:>9.1f}"
            f"{median(values):>9.1f}{hi:>9.1f}{hi / lo:>8.1f}x"
        )


def locate(whole: Samples, run: Samples, run_id: int) -> None:
    ew, ow = widths(list(run))
    print(f"\nrun {run_id} against that history:")
    print(f"{'example':<{ew}}{'os':<{ow}}{'value':>9}{'pct':>6}  verdict")
    for lane, values in sorted(run.items()):
        history = [v for v in whole.get(lane, []) if v not in values]
        value = median(values)
        if not history:
            print(
                f"{lane[0]:<{ew}}{lane[1]:<{ow}}{value:>9.1f}"
                f"{'':>6}  no history"
            )
            continue
        print(
            f"{lane[0]:<{ew}}{lane[1]:<{ow}}{value:>9.1f}"
            f"{percentile(history, value):>5.0f}%  {verdict(history, value)}"
        )


@app.command()
def main(
    source: Path = Path("bench/workflows.csv"),
    workflow: str = "seed-examples",
    step: str = "seed: package",
    run: int = 0,
) -> None:
    """Summarise STEP of WORKFLOW in SOURCE (bench-workflows) as a
    distribution per example and runner. With RUN, also place that run's
    value in the distribution of every *other* run, so a claimed win can
    be checked against the spread before it is believed."""
    whole, per_run = load(source, workflow, step)
    if not whole:
        raise typer.BadParameter(f"no successful {workflow!r} rows for {step!r}")
    report(whole)
    if run:
        if run not in per_run:
            raise typer.BadParameter(f"run {run} has no {step!r} rows")
        locate(whole, per_run[run], run)


if __name__ == "__main__":
    app()
