#!/usr/bin/env bats
#
# Checks that github.com still behaves the way the stubs in test/stubs assume.
# Needs network access. Run with: nix develop .#ci -c bats test/live

setup() {
  unset NO_COLOR PURPLECLAY_DEBUG PURPLECLAY_VERSION
  # Install into a temporary directory, never the real /usr/local/bin
  export PURPLECLAY_DIR="$BATS_TEST_TMPDIR/installed"
  bats_load_library bats-support
  bats_load_library bats-assert
  cd "$BATS_TEST_DIRNAME/../.." || exit 1
  # Build provenance is only checked with a logged-in gh, which CI gets from
  # GH_TOKEN. Without it every check would be skipped, so fail instead.
  gh auth status >/dev/null 2>&1 || fail "the live tests need gh logged in, or GH_TOKEN set"
}

# nsv is still released with GoReleaser, so it has no build provenance from
# release-workflows and isn't installed. Once nsv moves to release-workflows
# (issue 9), these assert success like release-note.
nsv_has_no_provenance() {
  assert_failure
  assert_output --regexp "The build provenance of nsv_[^ ]+ couldn't be verified"
}

@test "verifies the latest release of a Go and a Rust product" {
  run sh install.sh nsv
  nsv_has_no_provenance
  assert_output --regexp 'Resolved the latest release of nsv as v[0-9]+\.[0-9]+\.[0-9]+'
  assert_output --regexp 'Verified the checksum of nsv_[0-9.]+_(linux|darwin)_(x86_64|arm64)\.tar\.gz'

  run sh install.sh release-note
  assert_success
  assert_output --regexp 'Resolved the latest release of release-note as [0-9]+\.[0-9]+\.[0-9]+'
  assert_output --regexp 'Verified the build provenance of release-note-[0-9.]+-'
  assert_output --regexp 'Verified the checksum of release-note-[0-9.]+-(x86_64|aarch64)-[a-z-]+\.tar\.gz'
}

@test "resolves a version with or without a v, for Go and Rust tags" {
  for version in 0.12.2 v0.12.2; do
    run sh install.sh --version "$version" nsv
    nsv_has_no_provenance
    assert_output --partial "Resolved release v0.12.2 of nsv"
  done
  for version in 0.12.0 v0.12.0; do
    run sh install.sh --version "$version" release-note
    assert_success
    assert_output --partial "Resolved release 0.12.0 of release-note"
  done
}

@test "installs release-note, which reports the version it was installed as" {
  run sh install.sh release-note
  assert_success
  assert_output --regexp "Installed release-note [0-9.]+ into $PURPLECLAY_DIR"
  assert_output --regexp 'Checked release-note reports version [0-9]+\.[0-9]+\.[0-9]+'
  run "$PURPLECLAY_DIR/release-note" --version
  assert_success
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
  for tool in awk cat chmod gh grep gzip id install ls mkdir mktemp mv ps readlink rm sed \
    sha256sum shasum openssl sysctl tar tr uname; do
    ! tool_path=$(command -v "$tool") || ln -sf "$tool_path" "$bin/$tool"
  done
  ln -sf "$1" "$bin/wget"
  shift
  PATH="$bin" "$(command -v sh)" install.sh "$@"
}

@test "verifies releases with only GNU wget" {
  gnu_wget=$(command -v wget) && wget --help 2>&1 | grep -q -- --https-only ||
    skip "GNU wget isn't installed"

  run with_only_wget "$gnu_wget" nsv
  nsv_has_no_provenance
  assert_output --regexp 'Resolved the latest release of nsv as v[0-9]+\.[0-9]+\.[0-9]+'
  assert_output --partial "Verified the checksum of nsv_"

  # The Rust tag has no v, so this also follows a 404 to the other form
  run with_only_wget "$gnu_wget" --version v0.12.0 release-note
  assert_success
  assert_output --partial "Resolved release 0.12.0 of release-note"
  assert_output --partial "Verified the checksum of release-note-0.12.0-"
}

@test "refuses a busybox wget that can't verify certificates" {
  busybox=$(command -v busybox) || skip "busybox isn't installed"
  busybox wget -q --spider https://github.com 2>&1 | grep -q "validation not implemented" ||
    skip "this busybox verifies certificates"

  run with_only_wget "$busybox" nsv
  assert_failure
  assert_output --partial "This wget can't verify TLS certificates"
}
