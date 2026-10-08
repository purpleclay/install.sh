#!/usr/bin/env bats
#
# Run with: nix develop .#ci -c bats test
#
# The installer runs with a PATH holding only the stubs in test/stubs and the
# few tools it needs, so no test touches the network or depends on the host.

bats_require_minimum_version 1.5.0 # for run --separate-stderr

GITHUB=https://github.com/purpleclay

setup() {
  # Settings exported by whoever runs the tests would change the defaults
  # being tested
  unset NO_COLOR PURPLECLAY_DEBUG PURPLECLAY_VERSION COLORTERM LC_ALL LC_CTYPE \
    HTTPS_PROXY https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy \
    CURL_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR
  export LANG=C TERM=xterm-256color
  bats_load_library bats-support
  bats_load_library bats-assert
  cd "$BATS_TEST_DIRNAME/.." || exit 1
  ESC=$(printf '\033')

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  for tool in awk cat grep sed tr; do
    ln -s "$(command -v "$tool")" "$BIN/$tool"
  done
  # Optional: detect_shell falls back to these, and minimal systems lack ps
  for tool in ps readlink; do
    ! tool_path=$(command -v "$tool") || ln -s "$tool_path" "$BIN/$tool"
  done
  for stub in "$BATS_TEST_DIRNAME"/stubs/*; do
    ln -s "$stub" "$BIN/${stub##*/}"
  done

  # TEST_SHELL picks the shell that runs the installer, e.g. "bash --posix"
  shell="${TEST_SHELL:-sh}"
  shell_path=$(command -v "${shell%% *}") || fail "TEST_SHELL: ${shell%% *} isn't installed"
  shell="$shell_path${shell#"${shell%% *}"}"
  INSTALLER="$BATS_TEST_TMPDIR/install"
  cat >"$INSTALLER" <<EOF
#!/bin/sh
export PATH="$BIN"
exec $shell "$PWD/install.sh" "\$@"
EOF
  chmod +x "$INSTALLER"

  export STUB_ROUTES="$BATS_TEST_TMPDIR/routes" STUB_LOG="$BATS_TEST_TMPDIR/requests"
  : >"$STUB_LOG"
  route "$GITHUB/nsv/releases/latest" 302 "$GITHUB/nsv/releases/tag/v0.12.2"
  route "$GITHUB/nsv/releases/tag/v0.12.2" 200
}

# route URL STATUS [LOCATION]: how the stub curl and wget answer URL.
route() {
  echo "$*" >>"$STUB_ROUTES"
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

# ---------------------------------------------------------------------------
# Structure
# ---------------------------------------------------------------------------

@test "a copy cut off at any line runs nothing" {
  total=$(awk 'END { print NR }' install.sh)
  for n in $(seq 1 $((total - 1))); do
    awk -v n="$n" 'NR <= n' install.sh >"$BATS_TEST_TMPDIR/cut.sh"
    # shellcheck disable=SC2086 # shell may include arguments, e.g. bash --posix
    output=$(PATH="$BIN" $shell "$BATS_TEST_TMPDIR/cut.sh" nsv 2>&1) || true
    case "$output" in
      "" | *[Ss]yntax\ error* | *unexpected*) ;;
      *) fail "cut off after line $n, it printed: $output" ;;
    esac
  done
  run cat "$STUB_LOG"
  assert_output ""
}

# ---------------------------------------------------------------------------
# Arguments and output
# ---------------------------------------------------------------------------

@test "--help prints usage" {
  run "$INSTALLER" --help
  assert_success
  assert_output --partial "USAGE"
  assert_output --partial "--no-color"
  assert_output --partial "PURPLECLAY_VERSION"
}

@test "a missing product fails with a hint" {
  run "$INSTALLER"
  assert_failure
  assert_output --partial "No product was given"
  assert_output --partial "Run with --help"
}

@test "logs go to stderr, keeping stdout free" {
  run --separate-stderr "$INSTALLER" --debug nsv
  assert_success
  assert_output ""
  assert_stderr --partial "Resolved the latest release of nsv as v0.12.2"

  run --separate-stderr "$INSTALLER" --bogus
  assert_failure
  assert_output ""
  assert_stderr --partial "Unknown flag '--bogus'"
}

@test "each step is a verb, aligned in a column, then what it applies to" {
  run "$INSTALLER" nsv
  assert_success
  assert_line "    Detected the host platform as linux/x86_64"
  assert_line "    Resolved the latest release of nsv as v0.12.2"
  assert_line "     Warning Downloads aren't supported yet, so nothing was installed"
}

@test "errors line up with the steps, with hints under the message" {
  route "$GITHUB/nsv/releases/tag/9.9.9" 404
  route "$GITHUB/nsv/releases/tag/v9.9.9" 404
  run "$INSTALLER" -v 9.9.9 nsv
  assert_failure
  assert_output --partial "$(printf '%s\n%s' \
    "       Error There is no release 9.9.9 of nsv" \
    "             See $GITHUB/nsv/releases for the available versions")"
}

@test "piped output shows only results" {
  run "$INSTALLER" nsv
  refute_output --partial "Resolving"
  refute_output --partial "$ESC"
}

@test "no line ends with a full stop" {
  route "$GITHUB/nsv/releases/tag/9.9.9" 404
  route "$GITHUB/nsv/releases/tag/v9.9.9" 404
  for args in "nsv" "--debug nsv" "--debug -v 9.9.9 nsv" "--bogus" ""; do
    # shellcheck disable=SC2086 # split args into separate arguments
    run "$INSTALLER" $args
    # An ASCII ellipsis, "...", is fine
    refute_line --regexp '[^.]\.$'
  done
}

@test "debug output names the shell running the installer" {
  run "$INSTALLER" --debug nsv
  assert_success
  assert_line --regexp '^ +\| shell +[a-z]'
  refute_line --regexp '^ +\| shell +unknown$'
}

@test "debug output is off by default" {
  run "$INSTALLER" nsv
  refute_output --partial "Detecting the shell"
  refute_output --partial "uname reported"
}

@test "PURPLECLAY_DEBUG turns on debug output" {
  PURPLECLAY_DEBUG=true run "$INSTALLER" nsv
  assert_line "   Detecting the shell and environment..."
}

@test "--debug overrides PURPLECLAY_DEBUG" {
  PURPLECLAY_DEBUG=false run "$INSTALLER" --debug nsv
  assert_line "   Detecting the shell and environment..."
}

@test "debug output starts with the settings that affect the run" {
  PURPLECLAY_VERSION=v0.12.2 run "$INSTALLER" --debug nsv
  assert_success
  assert_line --regexp '^ +\| PURPLECLAY_VERSION +v0\.12\.2$'
  assert_line --regexp '^ +\| NO_COLOR +\(not set\)$'
  assert_line --regexp '^ +\| LANG +C$'
}

@test "debug output lists proxy settings only when set, without credentials" {
  run "$INSTALLER" --debug nsv
  refute_output --partial "HTTPS_PROXY"

  # With and without a scheme, as curl accepts both, and with an @ in the
  # password that wasn't percent-encoded
  for proxy in "http://alice:s3cret@proxy.example:3128|http://***@proxy.example:3128" \
    "alice:s3cret@proxy.example:3128|***@proxy.example:3128" \
    "http://alice:s3@cret@proxy.example:3128/|http://***@proxy.example:3128/"; do
    HTTPS_PROXY="${proxy%%|*}" run "$INSTALLER" --debug nsv
    assert_line --regexp "^ +\\| HTTPS_PROXY +$(printf '%s' "${proxy#*|}" | sed 's/[.*]/\\&/g')\$"
    refute_output --partial "s3cret"
    refute_output --partial "cret@"
  done
}

@test "debug output prints long values in full" {
  no_proxy_list="$(printf 'host%s.example,' 1 2 3 4 5 6 7 8 9 10)"
  NO_PROXY="$no_proxy_list" run "$INSTALLER" --debug nsv
  assert_line --regexp "^ +\\| NO_PROXY +$no_proxy_list\$"
}

@test "TERM=dumb turns colour off on a terminal" {
  TERM=dumb run on_tty "$INSTALLER" nsv
  refute_output --partial "$ESC"
}

@test "debug detail is printed as it happens, between a step and its result" {
  LANG=en_GB.UTF-8 run "$INSTALLER" --debug nsv
  assert_success
  assert_output --partial "$(printf '%s\n%s\n%s' \
    "   Detecting the host platform…" \
    "             │ uname reported Linux x86_64" \
    "    Detected the host platform as linux/x86_64")"
  assert_output --partial "$(printf '%s\n%s\n%s\n%s\n%s' \
    "   Resolving the latest release of nsv…" \
    "             │ Requests use curl --proto =https --tlsv1.2 --connect-timeout 10 --retry 2" \
    "             │ Releases are read from $GITHUB/nsv" \
    "             │ HEAD /releases/latest returned 302, redirecting to /releases/tag/v0.12.2" \
    "    Resolved the latest release of nsv as v0.12.2")"
}

@test "debug detail comes before a failure, so it's shown even if a step hangs" {
  route "$GITHUB/nsv/releases/tag/9.9.9" 404
  route "$GITHUB/nsv/releases/tag/v9.9.9" 404
  run "$INSTALLER" --debug -v 9.9.9 nsv
  assert_failure
  assert_output --partial "$(printf '%s\n%s\n%s\n%s' \
    "             | HEAD /releases/tag/v9.9.9 returned 404" \
    "             | HEAD /releases/latest returned 302, redirecting to /releases/tag/v0.12.2" \
    "       Error There is no release 9.9.9 of nsv" \
    "             See $GITHUB/nsv/releases for the available versions")"
}

@test "with --debug, headings are normal text and only the detail under them is faint" {
  LANG=en_GB.UTF-8 run on_tty "$INSTALLER" --debug nsv
  assert_success
  faint="${ESC}[2m"
  for heading in "the shell and environment" "the host platform" "the latest release of nsv"; do
    assert_line --partial "$heading…"
    refute_line --partial "$faint$heading"
  done
  assert_line --partial "${faint}│"
}

@test "without UTF-8, the debug gutter and ellipsis fall back to ASCII" {
  run "$INSTALLER" --debug nsv
  assert_success
  assert_line "   Detecting the host platform..."
  assert_line "             | uname reported Linux x86_64"
}

@test "output is coloured on a terminal" {
  run on_tty "$INSTALLER" nsv
  assert_output --partial "$ESC"
}

@test "piped output has no colour" {
  run "$INSTALLER" nsv
  assert_success
  refute_output --partial "$ESC"
}

@test "NO_COLOR turns colour off on a terminal" {
  NO_COLOR=1 run on_tty "$INSTALLER" nsv
  refute_output --partial "$ESC"
}

@test "argument errors fail with a pointer to --help and honour --no-color" {
  for args in "--no-color --bogus" "--bogus --no-color" "--no-color a b" "--no-color nsv -v"; do
    # shellcheck disable=SC2086 # split args into separate arguments
    run on_tty "$INSTALLER" $args
    assert_failure
    assert_output --regexp 'Error [A-Z]'
    assert_output --partial "Run with --help"
    refute_output --partial "$ESC"
  done
}

@test "product names may only contain a-z, 0-9 and -" {
  for product in NSV "nsv/../evil" "nsv?x=1" "nsv_x"; do
    run "$INSTALLER" "$product"
    assert_failure
    assert_output --partial "The product name '$product' isn't valid"
  done
  run cat "$STUB_LOG"
  assert_output ""
}

@test "versions must look like semver" {
  for version in latest 1.2 v1 1.2.3.4 "1.2.3/../x"; do
    run "$INSTALLER" -v "$version" nsv
    assert_failure
    assert_output --partial "The version '$version' isn't valid"
  done
  run cat "$STUB_LOG"
  assert_output ""
}

# ---------------------------------------------------------------------------
# Platform
# ---------------------------------------------------------------------------

@test "the platform is detected from uname" {
  for platform in "Linux x86_64 linux/x86_64" "Linux amd64 linux/x86_64" \
    "Linux aarch64 linux/arm64" "Linux arm64 linux/arm64" \
    "Darwin x86_64 darwin/x86_64" "Darwin arm64 darwin/arm64"; do
    # shellcheck disable=SC2086 # split into OS, architecture and expected
    set -- $platform
    STUB_OS=$1 STUB_ARCH=$2 run "$INSTALLER" nsv
    assert_success
    assert_line "    Detected the host platform as $3"
  done
}

@test "an x86_64 shell under Rosetta gets arm64" {
  STUB_OS=Darwin STUB_ARCH=x86_64 STUB_ROSETTA=1 run "$INSTALLER" nsv
  assert_success
  assert_line "    Detected the host platform as darwin/arm64"
}

@test "an unsupported operating system names the OS and architecture" {
  STUB_OS=FreeBSD STUB_ARCH=amd64 run "$INSTALLER" nsv
  assert_failure
  assert_output --partial "The operating system FreeBSD (amd64) isn't supported"
}

@test "an unsupported architecture names the OS and architecture" {
  STUB_OS=Linux STUB_ARCH=riscv64 run "$INSTALLER" nsv
  assert_failure
  assert_output --partial "The architecture riscv64 (Linux) isn't supported"
}

# ---------------------------------------------------------------------------
# Release tags
# ---------------------------------------------------------------------------

@test "the latest release is read from the redirect, not the GitHub API" {
  run "$INSTALLER" nsv
  assert_success
  assert_output --partial "Resolved the latest release of nsv as v0.12.2"
  run grep -c "$GITHUB/nsv/releases/latest" "$STUB_LOG"
  assert_output 1
  refute grep -q "api.github.com" "$STUB_LOG"
}

@test "requests are limited to HTTPS" {
  run "$INSTALLER" nsv
  assert_success
  run cat "$STUB_LOG"
  assert_output --partial "--proto =https"
}

@test "requests time out rather than hang" {
  run "$INSTALLER" nsv
  run cat "$STUB_LOG"
  assert_output --partial "--max-time 30"
  assert_output --partial "--connect-timeout 10"

  rm "$BIN/curl"
  : >"$STUB_LOG"
  run "$INSTALLER" nsv
  run cat "$STUB_LOG"
  assert_output --regexp '^wget .*-T 15 -t 2'

  : >"$STUB_LOG"
  STUB_WGET=busybox run "$INSTALLER" nsv
  run cat "$STUB_LOG"
  assert_output --regexp '^wget .*-T 15'
  refute_output --partial " -t "
}

@test "a version resolves with or without a v, for v-prefixed tags" {
  route "$GITHUB/go-tool/releases/tag/v0.1.0" 200
  route "$GITHUB/go-tool/releases/tag/0.1.0" 404
  for version in 0.1.0 v0.1.0; do
    run "$INSTALLER" --version "$version" go-tool
    assert_success
    assert_output --partial "Resolved release v0.1.0 of go-tool"
  done
}

@test "a version resolves with or without a v, for unprefixed tags" {
  route "$GITHUB/rust-tool/releases/tag/0.1.0" 200
  route "$GITHUB/rust-tool/releases/tag/v0.1.0" 404
  for version in 0.1.0 v0.1.0; do
    run "$INSTALLER" -v "$version" rust-tool
    assert_success
    assert_output --partial "Resolved release 0.1.0 of rust-tool"
  done
}

@test "PURPLECLAY_VERSION picks the version, and --version overrides it" {
  route "$GITHUB/nsv/releases/tag/v0.11.0" 200
  route "$GITHUB/nsv/releases/tag/v0.10.0" 200
  PURPLECLAY_VERSION=v0.11.0 run "$INSTALLER" nsv
  assert_output --partial "Resolved release v0.11.0 of nsv"
  PURPLECLAY_VERSION=v0.11.0 run "$INSTALLER" --version v0.10.0 nsv
  assert_output --partial "Resolved release v0.10.0 of nsv"
}

@test "a product without releases fails" {
  route "$GITHUB/new-tool/releases/latest" 302 "$GITHUB/new-tool/releases"
  route "$GITHUB/new-tool/releases" 200
  run "$INSTALLER" new-tool
  assert_failure
  assert_output --partial "There are no releases of new-tool yet"
}

@test "a product that doesn't exist fails" {
  route "$GITHUB/missing/releases/latest" 404
  run "$INSTALLER" missing
  assert_failure
  assert_output --partial "Couldn't find missing"

  route "$GITHUB/missing/releases/tag/1.0.0" 404
  route "$GITHUB/missing/releases/tag/v1.0.0" 404
  run "$INSTALLER" -v 1.0.0 missing
  assert_failure
  assert_output --partial "Couldn't find missing"
}

@test "a version that doesn't exist fails, pointing to the releases page" {
  route "$GITHUB/nsv/releases/tag/9.9.9" 404
  route "$GITHUB/nsv/releases/tag/v9.9.9" 404
  run "$INSTALLER" -v 9.9.9 nsv
  assert_failure
  assert_output --partial "There is no release 9.9.9 of nsv"
  assert_output --partial "$GITHUB/nsv/releases"
}

@test "an unreachable github.com fails with the reason" {
  : >"$STUB_ROUTES"
  run "$INSTALLER" nsv
  assert_failure
  assert_output --partial "Couldn't reach github.com: its address couldn't be found"
  assert_output --partial "Run with --debug for details"
}

@test "network failures explain what went wrong and how to fix it" {
  for case in "x28||the request timed out|Check your network connection" \
    "x60||its certificate couldn't be verified|CURL_CA_BUNDLE" \
    "x56|407|your proxy needs you to sign in (HTTP 407)|HTTPS_PROXY" \
    "x7||the connection was refused|Check your network connection"; do
    IFS='|' read -r code status reason hint <<EOF
$case
EOF
    : >"$STUB_ROUTES"
    route "$GITHUB/nsv/releases/latest" "$code" "$status"
    run "$INSTALLER" nsv
    assert_failure
    assert_output --partial "Couldn't reach github.com: $reason"
    assert_output --partial "$hint"
  done
}

@test "debug output keeps the downloader's own error" {
  : >"$STUB_ROUTES"
  route "$GITHUB/nsv/releases/latest" x60
  run "$INSTALLER" --debug nsv
  assert_failure
  assert_output --partial "HEAD /releases/latest failed with exit code 60: curl: (60) SSL certificate problem"
}

@test "HTTP errors from github.com aren't mistaken for a missing product or release" {
  for case in "429|github.com is limiting requests from your network" \
    "403|github.com refused the request (HTTP 403)" \
    "503|github.com returned a server error (HTTP 503)" \
    "418|Got an unexpected response from github.com (HTTP 418)"; do
    status=${case%%|*}
    message=${case#*|}
    : >"$STUB_ROUTES"
    route "$GITHUB/nsv/releases/latest" "$status"
    route "$GITHUB/nsv/releases/tag/1.0.0" "$status"
    route "$GITHUB/nsv/releases/tag/v1.0.0" "$status"

    run "$INSTALLER" nsv
    assert_failure
    assert_output --partial "$message"
    refute_output --partial "Couldn't find"

    run "$INSTALLER" -v 1.0.0 nsv
    assert_failure
    assert_output --partial "$message"
    refute_output --partial "There is no release"
  done
}

@test "a redirect anywhere unexpected fails" {
  for location in "http://github.com/purpleclay/odd/releases/tag/v1.0.0" \
    "https://evil.example/purpleclay/odd/releases/tag/v1.0.0" \
    "$GITHUB/other/releases/tag/v1.0.0" \
    "$GITHUB/odd/releases/tag/v1.0.0;rm"; do
    : >"$STUB_ROUTES"
    route "$GITHUB/odd/releases/latest" 302 "$location"
    route "$location" 200
    run "$INSTALLER" odd
    assert_failure
    assert_output --partial "Got an unexpected response from github.com"
  done
}

# ---------------------------------------------------------------------------
# Downloaders
# ---------------------------------------------------------------------------

@test "works with only curl" {
  rm "$BIN/wget"
  run "$INSTALLER" nsv
  assert_success
  assert_output --partial "Resolved the latest release of nsv as v0.12.2"
  run cat "$STUB_LOG"
  assert_output --regexp '^curl '
}

@test "works with only wget, limited to HTTPS" {
  rm "$BIN/curl"
  run "$INSTALLER" nsv
  assert_success
  assert_output --partial "Resolved the latest release of nsv as v0.12.2"
  run cat "$STUB_LOG"
  assert_output --regexp '^wget .*--https-only'
}

@test "works with only busybox wget, which has no --https-only" {
  rm "$BIN/curl"
  STUB_WGET=busybox run "$INSTALLER" nsv
  assert_success
  assert_output --partial "Resolved the latest release of nsv as v0.12.2"
}

@test "wget failing after a redirect is a network error, not a result" {
  rm "$BIN/curl"
  for wget in gnu busybox; do
    # The redirect target has no route, so the stub fails to reach it
    : >"$STUB_ROUTES"
    route "$GITHUB/nsv/releases/latest" 302 "$GITHUB/nsv/releases/tag/v0.12.2"
    STUB_WGET=$wget run "$INSTALLER" nsv
    assert_failure
    assert_output --partial "Couldn't reach github.com"
    refute_output --partial "Resolved"
  done
}

@test "a wget that can't verify certificates is refused" {
  rm "$BIN/curl"
  STUB_WGET=busybox-insecure run "$INSTALLER" nsv
  assert_failure
  assert_output --partial "This wget can't verify TLS certificates, so it isn't safe to use"
  assert_output --partial "Install curl, or a wget that verifies certificates"
  refute_output --partial "Resolved"
}

@test "fails without curl or wget" {
  rm "$BIN/curl" "$BIN/wget"
  run "$INSTALLER" nsv
  assert_failure
  assert_output --partial "Neither curl nor wget is installed"
}
