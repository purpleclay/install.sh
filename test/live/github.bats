#!/usr/bin/env bats
#
# Checks that github.com still behaves the way the stubs in test/stubs assume.
# Needs network access. Run with: nix develop .#ci -c bats test/live

setup() {
  unset NO_COLOR PURPLECLAY_DEBUG PURPLECLAY_VERSION
  bats_load_library bats-support
  bats_load_library bats-assert
  cd "$BATS_TEST_DIRNAME/../.." || exit 1
}

@test "resolves the latest release of a Go and a Rust product" {
  run sh install.sh release-go-smoke-test
  assert_success
  assert_output --regexp 'Resolved the latest release of release-go-smoke-test as v[0-9]+\.[0-9]+\.[0-9]+'

  run sh install.sh release-rust-smoke-test
  assert_success
  assert_output --regexp 'Resolved the latest release of release-rust-smoke-test as [0-9]+\.[0-9]+\.[0-9]+'
}

@test "resolves a version with or without a v, for Go and Rust tags" {
  for version in 0.1.0 v0.1.0; do
    run sh install.sh --version "$version" release-go-smoke-test
    assert_success
    assert_output --partial "Resolved release v0.1.0 of release-go-smoke-test"

    run sh install.sh --version "$version" release-rust-smoke-test
    assert_success
    assert_output --partial "Resolved release 0.1.0 of release-rust-smoke-test"
  done
}

@test "a product that doesn't exist fails" {
  run sh install.sh purpleclay-does-not-exist
  assert_failure
  assert_output --partial "Couldn't find purpleclay-does-not-exist"
}

# with_only_wget WGET ARGS...: run the installer with WGET as its only
# downloader, so curl can't be used instead.
with_only_wget() {
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  for tool in awk cat grep ps readlink sed sysctl tr uname; do
    ! tool_path=$(command -v "$tool") || ln -sf "$tool_path" "$bin/$tool"
  done
  ln -sf "$1" "$bin/wget"
  shift
  PATH="$bin" "$(command -v sh)" install.sh "$@"
}

@test "resolves releases with only GNU wget" {
  gnu_wget=$(command -v wget) && wget --help 2>&1 | grep -q -- --https-only ||
    skip "GNU wget isn't installed"

  run with_only_wget "$gnu_wget" release-go-smoke-test
  assert_success
  assert_output --regexp 'Resolved the latest release of release-go-smoke-test as v[0-9]+\.[0-9]+\.[0-9]+'

  # The Rust tag has no v, so this also follows a 404 to the other form
  run with_only_wget "$gnu_wget" --version v0.1.0 release-rust-smoke-test
  assert_success
  assert_output --partial "Resolved release 0.1.0 of release-rust-smoke-test"
}

@test "refuses a busybox wget that can't verify certificates" {
  busybox=$(command -v busybox) || skip "busybox isn't installed"
  busybox wget -q --spider https://github.com 2>&1 | grep -q "validation not implemented" ||
    skip "this busybox verifies certificates"

  run with_only_wget "$busybox" release-go-smoke-test
  assert_failure
  assert_output --partial "This wget can't verify TLS certificates"
}
