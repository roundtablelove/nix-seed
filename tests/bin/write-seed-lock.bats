#!/usr/bin/env bats

load helpers

setup() {
  common_setup

  WRITE_SEED_LOCK="${PROJECT_ROOT}/bin/write-seed-lock"
  export WRITE_SEED_LOCK

  RECORDS="${BATS_TEST_TMPDIR}/records"
  mkdir --parents "$RECORDS"
  export RECORDS

  # a bare origin plus a clone, so push/pull are real git operations
  # against a real remote and the retry path can be exercised offline.
  ORIGIN="${BATS_TEST_TMPDIR}/origin.git"
  REPO="${BATS_TEST_TMPDIR}/repo"
  git init --quiet --bare --initial-branch=master "$ORIGIN"
  git clone --quiet "$ORIGIN" "$REPO"
  git -C "$REPO" config user.email tester@example.com
  git -C "$REPO" config user.name tester
  mkdir --parents "$REPO/examples/rust" "$REPO/examples/curl"
  echo seed >"$REPO/examples/rust/flake.nix"
  echo seed >"$REPO/examples/curl/flake.nix"
  git -C "$REPO" add --all
  git -C "$REPO" commit --quiet --message "examples"
  git -C "$REPO" push --quiet origin master
  export ORIGIN REPO

  # the script reads the branch from here, as it does on a detached CI
  # checkout
  export GITHUB_REF_NAME=master
}

# write one digest record, the way `build-seed --record` would
record() { # record PATH SYSTEM DIGEST [TAG]
  local path=$1 system=$2 digest=$3 tag=${4-tag0000000000000000000000000000000000000}
  local dir="${RECORDS}/$(printf '%s' "${path}-${system}" | tr '/.' '--')"
  mkdir --parents "$dir"
  jq -n --sort-keys \
    --arg path "$path" --arg lock ".seed.lock" \
    --arg repository "ghcr.io/example/${path}/seed" \
    --arg tag "$tag" --arg system "$system" --arg digest "$digest" \
    '{ $path, $lock, $repository, $tag, $system, $digest }' \
    >"$dir/seed-digest.json"
}

full_cycle() {
  record examples/rust aarch64-linux sha256:rustlinux
  record examples/rust aarch64-darwin sha256:rustdarwin
  record examples/curl aarch64-linux sha256:curllinux
  record examples/curl aarch64-darwin sha256:curldarwin
}

@test "a whole cycle lands as one commit naming every system" {
  full_cycle

  run "$BASH_BIN" "$WRITE_SEED_LOCK" --repo "$REPO" "$RECORDS"
  assert_status 0

  # exactly one commit added, carrying every lock at once: the property
  # the whole change exists for.
  run git -C "$REPO" rev-list --count master
  assert_status 0
  [[ $output -eq 2 ]]

  run git -C "$REPO" show --stat --name-only --format= HEAD
  assert_output_contains "examples/curl/.seed.lock"
  assert_output_contains "examples/rust/.seed.lock"

  run jq -S . "$REPO/examples/rust/.seed.lock"
  assert_status 0
  assert_output_contains '"aarch64-darwin": "sha256:rustdarwin"'
  assert_output_contains '"aarch64-linux": "sha256:rustlinux"'
  assert_output_contains '"version": 1'

  # and it reached the remote
  run git -C "$ORIGIN" show master:examples/curl/.seed.lock
  assert_status 0
  assert_output_contains "sha256:curldarwin"
}

@test "the commit sha is reported on stdout and to GITHUB_OUTPUT" {
  full_cycle
  export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/gh-output"

  run "$BASH_BIN" "$WRITE_SEED_LOCK" --repo "$REPO" "$RECORDS"
  assert_status 0

  sha=$(git -C "$REPO" rev-parse HEAD)
  assert_output_contains "$sha"
  assert_file_contains "$GITHUB_OUTPUT" "sha=$sha"
}

@test "a flake missing from the records fails, and names it" {
  full_cycle

  run "$BASH_BIN" "$WRITE_SEED_LOCK" --repo "$REPO" \
    --expect '["examples/rust","examples/curl","examples/python"]' "$RECORDS"
  assert_status 1
  assert_output_contains "examples/python"

  # nothing committed: all or nothing
  run git -C "$REPO" rev-list --count master
  [[ $output -eq 1 ]]
}

@test "a leg that never uploaded fails, rather than locking one system" {
  record examples/rust aarch64-linux sha256:rustlinux
  record examples/rust aarch64-darwin sha256:rustdarwin
  record examples/curl aarch64-linux sha256:curllinux
  # curl's darwin leg produced no record

  run "$BASH_BIN" "$WRITE_SEED_LOCK" --repo "$REPO" "$RECORDS"
  assert_status 1
  assert_output_contains "different systems"

  run git -C "$REPO" rev-list --count master
  [[ $output -eq 1 ]]
}

@test "records from two different cycles are refused" {
  record examples/rust aarch64-linux sha256:rustlinux
  record examples/rust aarch64-darwin sha256:rustdarwin tag1111111111111111111111111111111111111

  run "$BASH_BIN" "$WRITE_SEED_LOCK" --repo "$REPO" "$RECORDS"
  assert_status 1
  assert_output_contains "disagree on tag"
}

@test "the same system recorded twice is refused" {
  record examples/rust aarch64-linux sha256:rustlinux
  record examples/rust aarch64-darwin sha256:rustdarwin
  mkdir --parents "${RECORDS}/duplicate"
  cp "${RECORDS}/examples-rust-aarch64-linux/seed-digest.json" \
    "${RECORDS}/duplicate/seed-digest.json"

  run "$BASH_BIN" "$WRITE_SEED_LOCK" --repo "$REPO" "$RECORDS"
  assert_status 1
  assert_output_contains "recorded twice"
}

@test "no records at all is an error, not an empty commit" {
  run "$BASH_BIN" "$WRITE_SEED_LOCK" --repo "$REPO" "$RECORDS"
  assert_status 1
  assert_output_contains "no digest records"
}

@test "re-running an identical cycle commits nothing" {
  full_cycle
  run "$BASH_BIN" "$WRITE_SEED_LOCK" --repo "$REPO" "$RECORDS"
  assert_status 0
  first=$(git -C "$REPO" rev-parse HEAD)

  run "$BASH_BIN" "$WRITE_SEED_LOCK" --repo "$REPO" "$RECORDS"
  assert_status 0
  assert_output_contains "already current"
  assert_output_contains "$first"

  run git -C "$REPO" rev-list --count master
  [[ $output -eq 2 ]]
}

@test "a push lost to an unrelated commit is retried onto it" {
  full_cycle

  # a second clone stands in for whoever else pushes to master during
  # the window between our pull and our push. the stub lets the first
  # push attempt fail, lands their commit, and then gets out of the way,
  # so the retry has something real to rebase onto.
  other="${BATS_TEST_TMPDIR}/other"
  git clone --quiet "$ORIGIN" "$other"
  git -C "$other" config user.email other@example.com
  git -C "$other" config user.name other
  echo "unrelated" >"$other/NOTES.md"
  git -C "$other" add NOTES.md
  git -C "$other" commit --quiet --message "unrelated work"
  export OTHER_REPO="$other"

  git() {
    if [[ " $* " == *" push "* && ! -f "${LOG_DIR}/pushed.once" ]]; then
      touch "${LOG_DIR}/pushed.once"
      # their commit wins the race while ours is in flight
      command git -C "$OTHER_REPO" push --quiet origin master
      return 1
    fi
    command git "$@"
  }
  export -f git

  run "$BASH_BIN" "$WRITE_SEED_LOCK" --repo "$REPO" "$RECORDS"
  assert_status 0

  # ours landed on top of theirs: both survive, and the locks are whole
  run git -C "$ORIGIN" show master:NOTES.md
  assert_status 0
  assert_output_contains "unrelated"

  run git -C "$ORIGIN" show master:examples/rust/.seed.lock
  assert_status 0
  assert_output_contains "sha256:rustdarwin"
  assert_output_contains "sha256:rustlinux"
}

@test "giving up after the last attempt reports failure and commits nothing" {
  full_cycle

  git() {
    if [[ " $* " == *" push "* ]]; then
      return 1
    fi
    command git "$@"
  }
  export -f git

  run "$BASH_BIN" "$WRITE_SEED_LOCK" --repo "$REPO" --attempts 2 "$RECORDS"
  assert_status 1
  assert_output_contains "could not push"

  unset -f git
  run git -C "$ORIGIN" rev-list --count master
  [[ $output -eq 1 ]]
}
