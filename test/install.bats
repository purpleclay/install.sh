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
    CURL_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR PURPLECLAY_DIR
  export LANG=C TERM=xterm-256color
  bats_load_library bats-support
  bats_load_library bats-assert
  cd "$BATS_TEST_DIRNAME/.." || exit 1
  ESC=$(printf '\033')

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  for tool in awk cat chmod grep id install ls mkdir mktemp mv rm sed tar tr; do
    ln -s "$(command -v "$tool")" "$BIN/$tool"
  done
  # Optional: detect_shell falls back to ps and readlink, and minimal systems
  # lack ps. Checksums use the first SHA-256 tool found. GNU tar needs gzip.
  for tool in ps readlink sha256sum shasum openssl gzip; do
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
export PATH="\${TEST_PATH:-$BIN}"
exec $shell "$PWD/install.sh" "\$@"
EOF
  chmod +x "$INSTALLER"

  export STUB_ROUTES="$BATS_TEST_TMPDIR/routes" STUB_LOG="$BATS_TEST_TMPDIR/requests"
  : >"$STUB_LOG"
  # The temporary directory is checked to be empty after a run
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  # Never the real /usr/local/bin
  export PURPLECLAY_DIR="$BATS_TEST_TMPDIR/prefix/bin"

  route "$GITHUB/nsv/releases/latest" 302 "$GITHUB/nsv/releases/tag/v0.12.2"
  route "$GITHUB/nsv/releases/tag/v0.12.2" 200
  # As published by GoReleaser, with archives for other platforms and formats
  release nsv v0.12.2 \
    nsv-0.12.2-1.x86_64.rpm nsv_0.12.2_amd64.deb \
    nsv_0.12.2_darwin_arm64.tar.gz nsv_0.12.2_darwin_arm64.tar.gz.sbom.json \
    nsv_0.12.2_darwin_x86_64.tar.gz nsv_0.12.2_darwin_x86_64.tar.gz.sbom.json \
    nsv_0.12.2_linux_arm64.tar.gz nsv_0.12.2_linux_armv7.tar.gz \
    nsv_0.12.2_linux_x86_64.tar.gz nsv_0.12.2_linux_x86_64.tar.gz.sbom.json \
    nsv_0.12.2_windows_x86_64.zip
}

# route URL STATUS [LOCATION | @FILE]: how the stub curl and wget answer URL,
# serving the contents of FILE as the body.
route() {
  echo "$*" >>"$STUB_ROUTES"
}

# release PRODUCT TAG FILE...: publish each FILE in release TAG of PRODUCT,
# listed in its checksums.txt.
release() {
  product=$1 tag=$2
  shift 2
  dir="$BATS_TEST_TMPDIR/releases/$product/$tag"
  mkdir -p "$dir"
  : >"$dir/checksums.txt"
  for file; do
    case "$file" in
      *.tar.gz) pack "$dir/$file" "$product" "${tag#v}" ;;
      *) printf '%s\n' "$product $tag $file" >"$dir/$file" ;;
    esac
    printf '%s  %s\n' "$(sha256 "$dir/$file")" "$file" >>"$dir/checksums.txt"
    asset "$product" "$tag" "$file"
  done
  asset "$product" "$tag" checksums.txt
}

# pack ARCHIVE PRODUCT VERSION: an archive holding a fake PRODUCT binary that
# prints VERSION when run with --version. Settings change what's packed:
#   BINARIES       paths of the binaries in the archive [default: PRODUCT]
#   REPORTS        the version the binaries print [default: VERSION]
#   VERSION_FLAG   the one flag they answer to [default: --version]
pack() {
  src="$BATS_TEST_TMPDIR/pack"
  rm -rf "$src"
  mkdir -p "$src"
  echo "$2" >"$src/README.md"
  for path in ${BINARIES-$2}; do
    mkdir -p "$src/$(dirname "$path")"
    # shellcheck disable=SC2016 # $1 belongs to the fake binary
    printf '#!/bin/sh\n[ "$1" = %s ] || exit 2\necho "%s %s"\n' \
      "${VERSION_FLAG:---version}" "$2" "${REPORTS:-$3}" >"$src/$path"
    chmod 755 "$src/$path"
  done
  tar -czf "$1" -C "$src" .
}

# asset PRODUCT TAG FILE: serve FILE from release TAG of PRODUCT the way
# github.com does, through a redirect to a signed URL.
asset() {
  cdn="https://release-assets.githubusercontent.com/$1/$3?sig=s3cret"
  route "$GITHUB/$1/releases/download/$2/$3" 302 "$cdn"
  route "$cdn" 200 "@$BATS_TEST_TMPDIR/releases/$1/$2/$3"
}

# tamper PRODUCT TAG FILE: change FILE after its checksum was published.
tamper() {
  echo "tampered" >>"$BATS_TEST_TMPDIR/releases/$1/$2/$3"
}

sha256() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1"
  else
    shasum -a 256 "$1"
  fi | awk '{ print $1 }'
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
  assert_output --partial "PURPLECLAY_DIR"
  assert_output --partial "[default: ~/.local/bin, or /usr/local/bin as root]"
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
  assert_line "  Downloaded nsv_0.12.2_linux_x86_64.tar.gz"
  assert_line "    Verified the checksum of nsv_0.12.2_linux_x86_64.tar.gz"
  assert_line "   Installed nsv v0.12.2 into $PURPLECLAY_DIR"
  assert_line "     Checked nsv reports version 0.12.2"
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
  # Downloads stop only when stalled, so large files aren't cut off
  assert grep -q -- ' -o .*--speed-limit 1 --speed-time 30' "$STUB_LOG"
  refute grep -q -- ' -o .*--max-time' "$STUB_LOG"

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
  release go-tool v0.1.0 go-tool-v0.1.0-linux-amd64.tar.gz
  for version in 0.1.0 v0.1.0; do
    run "$INSTALLER" --version "$version" go-tool
    assert_success
    assert_output --partial "Resolved release v0.1.0 of go-tool"
  done
}

@test "a version resolves with or without a v, for unprefixed tags" {
  route "$GITHUB/rust-tool/releases/tag/0.1.0" 200
  route "$GITHUB/rust-tool/releases/tag/v0.1.0" 404
  release rust-tool 0.1.0 rust-tool-0.1.0-x86_64-unknown-linux-musl.tar.gz
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
# Checksums
# ---------------------------------------------------------------------------

@test "the archive for the platform is chosen from checksums.txt" {
  for platform in "Linux x86_64 linux_x86_64" "Linux aarch64 linux_arm64" \
    "Darwin x86_64 darwin_x86_64" "Darwin arm64 darwin_arm64"; do
    # shellcheck disable=SC2086 # split into OS, architecture and expected
    set -- $platform
    STUB_OS=$1 STUB_ARCH=$2 run "$INSTALLER" nsv
    assert_success
    assert_line "  Downloaded nsv_0.12.2_$3.tar.gz"
    assert_line "    Verified the checksum of nsv_0.12.2_$3.tar.gz"
  done
}

@test "Rust target triples and their architecture names are understood" {
  route "$GITHUB/release-note/releases/latest" 302 "$GITHUB/release-note/releases/tag/0.12.0"
  release release-note 0.12.0 \
    release-note-0.12.0-aarch64-apple-darwin.tar.gz \
    release-note-0.12.0-aarch64-apple-darwin.tar.gz.spdx.json \
    release-note-0.12.0-aarch64-unknown-linux-musl.tar.gz \
    release-note-0.12.0-x86_64-apple-darwin.tar.gz \
    release-note-0.12.0-x86_64-unknown-linux-musl.tar.gz
  for platform in "Linux x86_64 x86_64-unknown-linux-musl" "Linux arm64 aarch64-unknown-linux-musl" \
    "Darwin x86_64 x86_64-apple-darwin" "Darwin arm64 aarch64-apple-darwin"; do
    # shellcheck disable=SC2086 # split into OS, architecture and expected
    set -- $platform
    STUB_OS=$1 STUB_ARCH=$2 run "$INSTALLER" release-note
    assert_success
    assert_line "    Verified the checksum of release-note-0.12.0-$3.tar.gz"
  done
}

@test "an x86_64 shell under Rosetta downloads the arm64 archive" {
  STUB_OS=Darwin STUB_ARCH=x86_64 STUB_ROSETTA=1 run "$INSTALLER" nsv
  assert_success
  assert_line "  Downloaded nsv_0.12.2_darwin_arm64.tar.gz"
}

@test "only whole words in archives of the product match, never parts of them" {
  route "$GITHUB/odd/releases/latest" 302 "$GITHUB/odd/releases/tag/v1.0.0"
  release odd v1.0.0 \
    odd_1.0.0_linux_x86_64v2.tar.gz odd_1.0.0_linuxish_amd64.tar.gz \
    oddity_1.0.0_linux_x86_64.tar.gz other-odd_1.0.0_linux_x86_64.tar.gz \
    odd_1.0.0_linux_x86_64.zip odd_1.0.0_linux_x86_64.tar.gz.sbom.json
  run "$INSTALLER" odd
  assert_failure
  assert_output --partial "There is no build for linux/x86_64 in release v1.0.0 of odd"
  refute grep -q "releases/download/v1.0.0/odd" "$STUB_LOG"
}

@test "no build for the platform lists the archives there are" {
  route "$GITHUB/mac-only/releases/latest" 302 "$GITHUB/mac-only/releases/tag/v1.0.0"
  release mac-only v1.0.0 mac-only_1.0.0_darwin_arm64.tar.gz mac-only_1.0.0_darwin_x86_64.tar.gz
  run "$INSTALLER" mac-only
  assert_failure
  assert_output --partial "$(printf '%s\n%s\n%s\n%s' \
    "       Error There is no build for linux/x86_64 in release v1.0.0 of mac-only" \
    "             The release has these archives:" \
    "               mac-only_1.0.0_darwin_arm64.tar.gz" \
    "               mac-only_1.0.0_darwin_x86_64.tar.gz")"
}

@test "more than one matching build fails, listing them" {
  route "$GITHUB/two-libc/releases/latest" 302 "$GITHUB/two-libc/releases/tag/1.0.0"
  release two-libc 1.0.0 \
    two-libc-1.0.0-x86_64-unknown-linux-gnu.tar.gz \
    two-libc-1.0.0-x86_64-unknown-linux-musl.tar.gz
  run "$INSTALLER" two-libc
  assert_failure
  assert_output --partial "$(printf '%s\n%s\n%s\n%s' \
    "       Error More than one build matches linux/x86_64 in release 1.0.0 of two-libc" \
    "             It's not clear which of these to install:" \
    "               two-libc-1.0.0-x86_64-unknown-linux-gnu.tar.gz" \
    "               two-libc-1.0.0-x86_64-unknown-linux-musl.tar.gz")"
}

@test "a release without checksums.txt is refused" {
  route "$GITHUB/legacy/releases/latest" 302 "$GITHUB/legacy/releases/tag/v0.1.0"
  route "$GITHUB/legacy/releases/download/v0.1.0/checksums.txt" 404
  run "$INSTALLER" legacy
  assert_failure
  assert_output --partial "Release v0.1.0 of legacy has no checksums.txt, so it can't be verified"
  assert_output --partial "See $GITHUB/legacy#install for other ways to install it"
}

@test "an archive listed in checksums.txt but missing from the release fails" {
  : >"$STUB_ROUTES"
  route "$GITHUB/nsv/releases/latest" 302 "$GITHUB/nsv/releases/tag/v0.12.2"
  route "$GITHUB/nsv/releases/download/v0.12.2/nsv_0.12.2_linux_x86_64.tar.gz" 404
  release nsv v0.12.2 nsv_0.12.2_linux_x86_64.tar.gz
  run "$INSTALLER" nsv
  assert_failure
  assert_output --partial "Couldn't download nsv_0.12.2_linux_x86_64.tar.gz (HTTP 404)"
}

@test "a tampered archive fails, is deleted, and nothing else happens" {
  tamper nsv v0.12.2 nsv_0.12.2_linux_x86_64.tar.gz
  expected=$(awk '$2 == "nsv_0.12.2_linux_x86_64.tar.gz" { print $1 }' \
    "$BATS_TEST_TMPDIR/releases/nsv/v0.12.2/checksums.txt")
  actual=$(sha256 "$BATS_TEST_TMPDIR/releases/nsv/v0.12.2/nsv_0.12.2_linux_x86_64.tar.gz")
  run "$INSTALLER" nsv
  assert_failure
  assert_output --partial "$(printf '%s\n%s\n%s\n%s' \
    "       Error The checksum of nsv_0.12.2_linux_x86_64.tar.gz doesn't match checksums.txt" \
    "             Expected $expected" \
    "             Got      $actual" \
    "             The download may be corrupt or tampered with, so it was deleted")"
  refute_output --partial "Verified"
  refute_output --partial "Warning"
  run find "$TMPDIR" -mindepth 1
  assert_output ""
}

@test "the checksum check can't be turned off" {
  tamper nsv v0.12.2 nsv_0.12.2_linux_x86_64.tar.gz
  run "$INSTALLER" --skip-checksum nsv
  assert_failure
  assert_output --partial "Unknown flag '--skip-checksum'"

  PURPLECLAY_SKIP_CHECKSUM=true PURPLECLAY_INSECURE=true run "$INSTALLER" nsv
  assert_failure
  assert_output --partial "doesn't match checksums.txt"
}

@test "checksums use sha256sum, then shasum, then openssl" {
  for tool in sha256sum shasum openssl; do
    [ -e "$BIN/$tool" ] || skip "$tool isn't installed"
  done
  for tool in sha256sum shasum openssl; do
    run "$INSTALLER" --debug nsv
    assert_success
    assert_line --regexp "^ +\\| Computed with +$tool\$"
    assert_line "    Verified the checksum of nsv_0.12.2_linux_x86_64.tar.gz"
    rm "${BIN:?}/${tool:?}"
  done

  run "$INSTALLER" nsv
  assert_failure
  assert_output --partial "There is no tool to compute a SHA-256 checksum with"
  assert_output --partial "Install sha256sum, shasum or openssl, then try again"
}

@test "temporary files are removed after success and failure" {
  run "$INSTALLER" nsv
  assert_success
  run find "$TMPDIR" -mindepth 1
  assert_output ""

  route "$GITHUB/mac-only/releases/latest" 302 "$GITHUB/mac-only/releases/tag/v1.0.0"
  release mac-only v1.0.0 mac-only_1.0.0_darwin_arm64.tar.gz
  run "$INSTALLER" mac-only
  assert_failure
  run find "$TMPDIR" -mindepth 1
  assert_output ""
}

@test "downloads follow redirects only to HTTPS" {
  run "$INSTALLER" nsv
  assert_success
  run grep "releases/download" "$STUB_LOG"
  assert_output --partial "--proto-redir =https"
  assert_output --partial "--proto =https"

  # busybox wget can't be told to stay on HTTPS, so where it ended up is checked
  rm "${BIN:?}/curl"
  : >"$STUB_ROUTES"
  route "$GITHUB/nsv/releases/latest" 302 "$GITHUB/nsv/releases/tag/v0.12.2"
  route "$GITHUB/nsv/releases/tag/v0.12.2" 200
  route "$GITHUB/nsv/releases/download/v0.12.2/checksums.txt" 302 "http://cdn.example/checksums.txt"
  route "http://cdn.example/checksums.txt" 200 "@$BATS_TEST_TMPDIR/releases/nsv/v0.12.2/checksums.txt"
  STUB_WGET=busybox run "$INSTALLER" nsv
  assert_failure
  assert_output --partial "The download was redirected to http://cdn.example/checksums.txt, which isn't HTTPS"
  refute_output --partial "Downloaded"
}

@test "debug output shows downloads without their signed URLs" {
  run "$INSTALLER" --debug nsv
  assert_success
  assert_line --regexp '^ +\| GET /releases/download/v0\.12\.2/checksums\.txt returned 200 from release-assets\.githubusercontent\.com$'
  assert_line --regexp '^ +\| Selected +nsv_0\.12\.2_linux_x86_64\.tar\.gz$'
  refute_output --partial "s3cret"
}

# ---------------------------------------------------------------------------
# Installing
# ---------------------------------------------------------------------------

# locked DIR: create DIR, then stop the test user writing to it. root can
# write to it anyway, so tests that need a locked directory skip as root.
locked() {
  [ "$(id -u)" != 0 ] || skip "root can write to any directory"
  mkdir -p "$1"
  chmod 555 "$1"
}

@test "installs the binary into PURPLECLAY_DIR, creating it, or into --dir" {
  run "$INSTALLER" nsv
  assert_success
  run "$PURPLECLAY_DIR/nsv" --version
  assert_output "nsv 0.12.2"

  for flag in --dir -d; do
    run "$INSTALLER" "$flag" "$BATS_TEST_TMPDIR/other$flag" nsv
    assert_success
    assert_line "   Installed nsv v0.12.2 into $BATS_TEST_TMPDIR/other$flag"
    [ -x "$BATS_TEST_TMPDIR/other$flag/nsv" ]
  done
}

@test "a relative --dir is resolved against the current directory" {
  cd "$BATS_TEST_TMPDIR"
  run "$INSTALLER" --dir relative/bin nsv
  assert_success
  assert_line "   Installed nsv v0.12.2 into $BATS_TEST_TMPDIR/relative/bin"
  [ -x "$BATS_TEST_TMPDIR/relative/bin/nsv" ]
}

@test "replaces an existing binary, leaving nothing else behind" {
  mkdir -p "$PURPLECLAY_DIR"
  echo "old" >"$PURPLECLAY_DIR/nsv"
  run "$INSTALLER" nsv
  assert_success
  run "$PURPLECLAY_DIR/nsv" --version
  assert_output "nsv 0.12.2"
  run ls -A "$PURPLECLAY_DIR"
  assert_output "nsv"
}

@test "a directory that isn't writable fails, without asking for more privileges" {
  locked "$BATS_TEST_TMPDIR/locked"
  for dir in "$BATS_TEST_TMPDIR/locked" "$BATS_TEST_TMPDIR/locked/bin"; do
    run "$INSTALLER" --dir "$dir" nsv
    assert_failure
    assert_output --partial "Error $BATS_TEST_TMPDIR/locked isn't writable, so nsv can't be installed into $dir"
    assert_output --partial "Choose a directory you can write to with --dir, or run the installer as root"
  done
}

@test "installs into ~/.local/bin by default" {
  # As root it would install into the real /usr/local/bin
  [ "$(id -u)" != 0 ] || skip "root installs into /usr/local/bin by default"
  unset PURPLECLAY_DIR
  export HOME="$BATS_TEST_TMPDIR/home"
  run "$INSTALLER" nsv
  assert_success
  assert_line "   Installed nsv v0.12.2 into $HOME/.local/bin"
  [ -x "$HOME/.local/bin/nsv" ]
}

@test "finds the binary inside a single nested directory" {
  BINARIES="nsv_0.12.2_linux_x86_64/nsv" release nsv v0.12.2 nsv_0.12.2_linux_x86_64.tar.gz
  run "$INSTALLER" nsv
  assert_success
  assert_line "   Installed nsv v0.12.2 into $PURPLECLAY_DIR"
}

@test "an archive without the binary, or with two, fails" {
  BINARIES="" release nsv v0.12.2 nsv_0.12.2_linux_x86_64.tar.gz
  run "$INSTALLER" nsv
  assert_failure
  assert_output --partial "Error nsv_0.12.2_linux_x86_64.tar.gz doesn't contain the nsv binary"

  BINARIES="nsv other/nsv" release nsv v0.12.2 nsv_0.12.2_linux_x86_64.tar.gz
  run "$INSTALLER" nsv
  assert_failure
  assert_output --partial "Error nsv_0.12.2_linux_x86_64.tar.gz contains more than one nsv binary"
  [ ! -e "$PURPLECLAY_DIR/nsv" ]
}

@test "the version check falls back to -V" {
  VERSION_FLAG=-V release nsv v0.12.2 nsv_0.12.2_linux_x86_64.tar.gz
  run "$INSTALLER" nsv
  assert_success
  assert_line "     Checked nsv reports version 0.12.2"
}

@test "the version check runs the verified binary, not another copy on PATH" {
  printf '#!/bin/sh\necho "nsv 9.9.9"\n' >"$BIN/nsv"
  chmod 755 "$BIN/nsv"
  run "$INSTALLER" nsv
  assert_success
  assert_line "     Checked nsv reports version 0.12.2"
}

@test "the version check passes before the binary is installed" {
  run "$INSTALLER" nsv
  assert_success
  assert_output --partial "$(printf '%s\n%s' \
    "     Checked nsv reports version 0.12.2" \
    "   Installed nsv v0.12.2 into $PURPLECLAY_DIR")"
}

@test "a failed version check leaves an existing binary in place" {
  mkdir -p "$PURPLECLAY_DIR"
  printf '#!/bin/sh\necho "nsv 0.12.1"\n' >"$PURPLECLAY_DIR/nsv"
  chmod 755 "$PURPLECLAY_DIR/nsv"
  REPORTS=9.9.9 release nsv v0.12.2 nsv_0.12.2_linux_x86_64.tar.gz
  run "$INSTALLER" nsv
  assert_failure
  run "$PURPLECLAY_DIR/nsv"
  assert_output "nsv 0.12.1"
  run ls -A "$PURPLECLAY_DIR"
  assert_output "nsv"
}

@test "a binary reporting another version, or none, fails the version check" {
  REPORTS=9.9.9 release nsv v0.12.2 nsv_0.12.2_linux_x86_64.tar.gz
  run "$INSTALLER" nsv
  assert_failure
  assert_output --partial "Error nsv_0.12.2_linux_x86_64.tar.gz reports nsv 9.9.9 rather than version 0.12.2"

  VERSION_FLAG=--other release nsv v0.12.2 nsv_0.12.2_linux_x86_64.tar.gz
  run "$INSTALLER" nsv
  assert_failure
  assert_output --partial "Error nsv_0.12.2_linux_x86_64.tar.gz reports nothing rather than version 0.12.2"
  assert_output --partial "Report this at $GITHUB/nsv/issues"
}

@test "the version check compares whole versions, not parts of them" {
  for reported in 0.12.20 10.12.2 0.12.2.1; do
    REPORTS=$reported release nsv v0.12.2 nsv_0.12.2_linux_x86_64.tar.gz
    run "$INSTALLER" nsv
    assert_failure
    assert_output --partial "reports nsv $reported rather than version 0.12.2"
  done

  for reported in v0.12.2 "(0.12.2)"; do
    REPORTS=$reported release nsv v0.12.2 nsv_0.12.2_linux_x86_64.tar.gz
    run "$INSTALLER" nsv
    assert_success
    assert_line "     Checked nsv reports version 0.12.2"
  done
}

@test "a directory where the binary goes fails, before anything is installed" {
  mkdir -p "$PURPLECLAY_DIR/nsv"
  run "$INSTALLER" nsv
  assert_failure
  assert_output --partial "Error $PURPLECLAY_DIR/nsv is a directory, so nsv can't be installed there"
  run ls -A "$PURPLECLAY_DIR/nsv"
  assert_output ""
  run ls -A "$PURPLECLAY_DIR"
  assert_output "nsv"
}

@test "an install interrupted before the rename leaves nothing behind" {
  # Interrupts the installer while it renames the staged binary into place
  rm "$BIN/mv"
  # shellcheck disable=SC2016 # $PPID belongs to the stub mv
  printf '#!/bin/sh\nkill -TERM "$PPID"\n' >"$BIN/mv"
  chmod 755 "$BIN/mv"
  run "$INSTALLER" nsv
  assert_failure
  run ls -A "$PURPLECLAY_DIR"
  assert_output ""
  run find "$TMPDIR" -mindepth 1
  assert_output ""
}

@test "as root, a directory other users could change is refused before installing" {
  [ "$(id -u)" != 0 ] || skip "needs directories owned by a user other than root"
  # Pretends to be root. The test's own directories belong to the test user.
  rm "$BIN/id"
  printf '#!/bin/sh\necho 0\n' >"$BIN/id"
  chmod 755 "$BIN/id"

  run "$INSTALLER" nsv
  assert_failure
  assert_output --partial "can be changed by users other than root, so installing into $PURPLECLAY_DIR as root isn't safe"
  assert_output --partial "Install into a directory only root can change, such as /usr/local/bin, or run the installer as a normal user"
  [ ! -e "$PURPLECLAY_DIR/nsv" ]
}

@test "as root, . or .. in a directory still to be created is refused" {
  rm "$BIN/id"
  printf '#!/bin/sh\necho 0\n' >"$BIN/id"
  chmod 755 "$BIN/id"

  for dir in "$BATS_TEST_TMPDIR/new/../../elsewhere/bin" "$BATS_TEST_TMPDIR/new/./bin" "$BATS_TEST_TMPDIR/new/.."; do
    run "$INSTALLER" --dir "$dir" nsv
    assert_failure
    assert_output --partial "Error $dir uses . or .. in a part that doesn't exist yet, so where it leads can't be checked"
    assert_output --partial "Give the directory without . or .., then try again"
  done
}

@test "warns when the install directory isn't on PATH" {
  run "$INSTALLER" nsv
  assert_success
  assert_output --partial "$(printf '%s\n%s' \
    "     Warning $PURPLECLAY_DIR isn't on your PATH, so run nsv with its full path" \
    "             Add it to PATH in your shell's profile, then open a new terminal, to run nsv by name")"

  # The installer runs with BIN as its PATH
  run "$INSTALLER" --dir "$BIN" nsv
  assert_success
  refute_output --partial "isn't on your PATH"

  # A trailing slash in PATH names the same directory
  TEST_PATH="$BIN:$PURPLECLAY_DIR/" run "$INSTALLER" nsv
  assert_success
  refute_output --partial "isn't on your PATH"
}

# ---------------------------------------------------------------------------
# Downloaders
# ---------------------------------------------------------------------------

@test "works with only curl" {
  rm "$BIN/wget"
  run "$INSTALLER" nsv
  assert_success
  assert_output --partial "Verified the checksum of nsv_0.12.2_linux_x86_64.tar.gz"
  run cat "$STUB_LOG"
  assert_output --regexp '^curl '
}

@test "works with only wget, limited to HTTPS" {
  rm "$BIN/curl"
  run "$INSTALLER" nsv
  assert_success
  assert_output --partial "Verified the checksum of nsv_0.12.2_linux_x86_64.tar.gz"
  run cat "$STUB_LOG"
  assert_output --regexp '^wget .*--https-only'
}

@test "works with only busybox wget, which has no --https-only" {
  rm "$BIN/curl"
  STUB_WGET=busybox run "$INSTALLER" nsv
  assert_success
  assert_output --partial "Verified the checksum of nsv_0.12.2_linux_x86_64.tar.gz"
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
