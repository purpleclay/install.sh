#!/usr/bin/env bats
#
# Run with: nix develop .#ci -c bats test

bats_require_minimum_version 1.5.0 # for run --separate-stderr

setup() {
  # Settings exported by whoever runs the tests would change the defaults
  # being tested
  unset NO_COLOR PURPLECLAY_DEBUG
  bats_load_library bats-support
  bats_load_library bats-assert
  cd "$BATS_TEST_DIRNAME/.." || exit 1
  ESC=$(printf '\033')
}

# on_tty CMD...: run CMD on a pseudo-terminal, so the installer turns colour
# on unless something stops it. BSD and util-linux script take different
# arguments.
on_tty() {
  if script --version >/dev/null 2>&1; then
    script -qec "$*" /dev/null
  else
    script -q /dev/null "$@"
  fi </dev/null
}

@test "--help prints usage" {
  run sh install.sh --help
  assert_success
  assert_output --partial "USAGE"
  assert_output --partial "--no-color"
}

@test "a missing product fails with a hint" {
  run sh install.sh
  assert_failure
  assert_output --partial "no product given"
  assert_output --partial "Run with --help"
}

@test "logs go to stderr, keeping stdout free" {
  run --separate-stderr sh install.sh --debug nsv
  assert_success
  assert_output ""
  assert_stderr --partial "installing nsv"

  run --separate-stderr sh install.sh --bogus
  assert_failure
  assert_output ""
  assert_stderr --partial "unknown flag '--bogus'"
}

@test "debug output is off by default" {
  run sh install.sh nsv
  refute_line --regexp '^debug '
}

@test "PURPLECLAY_DEBUG turns on debug output" {
  PURPLECLAY_DEBUG=true run sh install.sh nsv
  assert_line --regexp '^debug '
}

@test "--debug overrides PURPLECLAY_DEBUG" {
  PURPLECLAY_DEBUG=false run sh install.sh --debug nsv
  assert_line --regexp '^debug '
}

@test "output is coloured on a terminal" {
  run on_tty sh install.sh nsv
  assert_output --partial "$ESC"
}

@test "piped output has no colour" {
  run sh install.sh nsv
  assert_success
  refute_output --partial "$ESC"
}

@test "NO_COLOR turns colour off on a terminal" {
  NO_COLOR=1 run on_tty sh install.sh nsv
  refute_output --partial "$ESC"
}

@test "argument errors fail with a pointer to --help and honour --no-color" {
  for args in "--no-color --bogus" "--bogus --no-color" "--no-color a b"; do
    # shellcheck disable=SC2086 # split args into separate arguments
    run on_tty sh install.sh $args
    assert_failure
    assert_output --partial "error"
    assert_output --partial "Run with --help"
    refute_output --partial "$ESC"
  done
}
