#!/bin/sh
#
# purpleclay installer: one script to install them all.
#
#   curl -fsSL https://get.purpleclay.io | sh -s -- <product>
#
# Source: https://github.com/purpleclay/install.sh
# Docs:   sh install.sh --help
#
# Nothing runs until `main "$@"` on the final line. If this script is cut off
# while being piped into a shell, the shell only defines functions and exits.

# Replaced with the release's version, such as 1.2.3, when the script is deployed
INSTALLER_VERSION="dev"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

is_true() {
  case "$1" in
    1 | true | TRUE | True | yes | YES | on | ON) return 0 ;;
    *) return 1 ;;
  esac
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Styling. All escape codes are built here, so the call sites never change
# when the brand theme is applied.
# ---------------------------------------------------------------------------

# init_style FD: colour only when FD is a terminal that understands escapes,
# and NO_COLOR is unset. Glyphs fall back to ASCII when the locale isn't UTF-8.
init_style() {
  ESC=$(printf '\033')
  COLOR=false
  if [ -z "${NO_COLOR:-}" ] && ! is_true "$OPT_NO_COLOR" && [ -t "$1" ] &&
    [ "${TERM:-}" != dumb ]; then
    COLOR=true
  fi

  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8* | *utf-8* | *UTF8* | *utf8*) UTF8=true GUTTER='│' ELLIPSIS='…' SEP='·' ;;
    *) UTF8=false GUTTER='|' ELLIPSIS='...' SEP='-' ;;
  esac
}

# style SGR TEXT: wrap TEXT in an SGR escape sequence, e.g. style 31 "red".
style() {
  if [ "$COLOR" = true ]; then
    printf '%s[%sm%s%s[0m' "$ESC" "$1" "$2" "$ESC"
  else
    printf '%s' "$2"
  fi
}

bold() { style 1 "$1"; }
faint() { style 2 "$1"; }

# shade SHADE: set _sgr to a shade from the purpleclay brand palette, without
# the 38 (foreground) or 48 (background) prefix. Uses 24-bit colour when the
# terminal says it supports it, otherwise the nearest of the 256 xterm colours.
shade() {
  case "$1" in
    50) _rgb='169;128;219' _idx=140 ;; # #a980db
    100) _rgb='144;108;207' _idx=98 ;; # #906ccf
    200) _rgb='121;88;195' _idx=97 ;;  # #7958c3
    300) _rgb='98;68;183' _idx=61 ;;   # #6244b7
    400) _rgb='75;48;171' _idx=55 ;;   # #4b30ab
    500) _rgb='61;40;150' _idx=54 ;;   # #3d2896
  esac
  case "${COLORTERM:-}" in
    truecolor | 24bit) _sgr="2;$_rgb" ;;
    *) _sgr="5;$_idx" ;;
  esac
}

# purple SHADE TEXT
purple() {
  shade "$1"
  style "38;$_sgr" "$2"
}

# ---------------------------------------------------------------------------
# Logging. Everything goes to stderr; stdout is kept for machine-readable
# output.
#
# Each line starts with a word, right-aligned in a column of its own:
#
#      Resolved the latest release of nsv as v0.12.2
#       Warning Downloads aren't supported yet, so nothing was installed
#         Error There is no release 9.9.9 of nsv
#               See https://github.com/purpleclay/nsv/releases for ...
#
# The words carry the meaning, so output reads the same without colour or
# UTF-8. Every line is a phrase without a full stop, the way cargo prints.
#
# Debug detail is printed the moment it's known, under a heading for the step
# it belongs to, so a step that hangs still shows what it was doing.
# ---------------------------------------------------------------------------

# Hints and debug detail line up with the text after the verb column.
INDENT="             "

# label SGR VERB: VERB right-aligned in the verb column.
label() {
  style "1;$1" "$(printf '%12s' "$2")"
}

# brand_label VERB: a verb in the brand purple. Purple100 is used because it
# reads about equally well on dark and light backgrounds, and the installer
# never asks the terminal which it has.
brand_label() {
  shade 100
  label "38;$_sgr" "$1"
}

# begin VERB TEXT: with --debug, a heading for the detail that follows, as a
# step starts. Without it, only results are shown.
begin() {
  is_true "$OPT_DEBUG" || return 0
  printf '%s %s\n' "$(brand_label "$1")" "$2$ELLIPSIS" >&2
}

# done_step VERB TEXT: a step that succeeded.
done_step() {
  printf '%s %s\n' "$(brand_label "$1")" "$2" >&2
}

# warn MESSAGE [HINT...]: something to know about, followed by hints.
warn() {
  printf '%s %s\n' "$(label 33 Warning)" "$1" >&2
  shift
  hints "$@"
}

# die MESSAGE [HINT...]: a failed step, followed by hints on what to do next.
die() {
  printf '%s %s\n' "$(label 31 Error)" "$1" >&2
  shift
  hints "$@"
  exit 1
}

# hints HINT...: lines under a warning or error. A hint can span several lines.
hints() {
  for _hint in "$@"; do
    printf '%s\n' "$_hint" | sed "s/^/$INDENT/" >&2
  done
}

# debug MESSAGE: detail for --debug, printed straight away.
debug() {
  is_true "$OPT_DEBUG" || return 0
  printf '%s%s %s\n' "$INDENT" "$(faint "$GUTTER")" "$(faint "$1")" >&2
}

# debug_pair NAME VALUE: a debug line laid out as an aligned table row.
debug_pair() {
  debug "$(printf '%-19s %s' "$1" "$2")"
}

# redact URL: hide any user name and password, such as in a proxy URL, so
# debug output can be pasted into an issue.
redact() {
  # curl accepts a proxy with or without a scheme. Matching up to the last @
  # before the host also hides a password holding an unencoded @.
  printf '%s' "$1" | sed -e 's#://[^/]*@#://***@#' -e t -e 's#^[^/]*@#***@#'
}

# debug_context: the shell and settings that affect the run, printed before
# the first step, so a bug report holds what's needed to reproduce it.
debug_context() {
  is_true "$OPT_DEBUG" || return 0
  begin Detecting "the shell and environment"
  debug_pair shell "$(detect_shell)"

  # Settings the installer documents are always listed. Settings that
  # change how requests are made are listed only when set, to keep this short.
  for _var in PURPLECLAY_DEBUG PURPLECLAY_VERSION PURPLECLAY_DIR NO_COLOR COLORTERM TERM LANG LC_ALL LC_CTYPE; do
    eval "_value=\${$_var-(not set)}"
    debug_pair "$_var" "$_value"
  done
  for _var in HTTPS_PROXY https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy \
    CURL_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR; do
    eval "_value=\${$_var-}"
    [ -z "$_value" ] || debug_pair "$_var" "$(redact "$_value")"
  done
}

# detect_shell: the shell running the installer. Its name isn't in $0 when
# the script is piped in, so the shells' own variables are checked first.
detect_shell() {
  if [ -n "${BASH_VERSION:-}" ]; then
    printf 'bash %s' "$BASH_VERSION"
  elif [ -n "${ZSH_VERSION:-}" ]; then
    printf 'zsh %s' "$ZSH_VERSION"
  elif [ -n "${KSH_VERSION:-}" ]; then
    printf '%s' "$KSH_VERSION"
  elif have readlink && _exe=$(readlink "/proc/$$/exe" 2>/dev/null) && [ -n "$_exe" ]; then
    printf '%s' "${_exe##*/}"
  elif have ps && _exe=$(ps -p "$$" -o comm= 2>/dev/null) && [ -n "$_exe" ]; then
    printf '%s' "${_exe##*/}"
  else
    printf 'unknown'
  fi
}

# ---------------------------------------------------------------------------
# Banner and help
# ---------------------------------------------------------------------------

banner() {
  _title=$(bold "$(purple 100 'purpleclay')")
  _tagline="One script to install them all"
  _version=$(faint "install.sh $INSTALLER_VERSION")

  # The ring needs colour and UTF-8. Without them, which mostly means CI logs,
  # piped output and minimal containers, a single line is enough.
  printf '\n'
  if [ "$COLOR" = true ] && [ "$UTF8" = true ]; then
    ring "$_title" "$_tagline" "$_version"
  else
    printf '%s %s %s %s %s\n' "$_title" "$SEP" "$_tagline" "$SEP" "$_version"
  fi
  printf '\n'
}

# ring TITLE TAGLINE VERSION: a shaded ring drawn with half blocks, so each
# character cell holds two pixels. In the grid, each digit is a shade from 1
# (Purple50, lit) to 6 (Purple500) and dots are empty.
ring() {
  _pal=""
  for _s in 50 100 200 300 400 500; do
    shade "$_s"
    _pal="$_pal $_sgr"
  done

  awk -v pal="$_pal" -v esc="$ESC" -v t1="$1" -v t2="$2" -v t3="$3" '
    function cell(top, bot) {
      if (top == "." && bot == ".") return " "
      if (bot == ".") return esc "[38;" p[top] "m▀" esc "[0m"
      if (top == ".") return esc "[38;" p[bot] "m▄" esc "[0m"
      return esc "[38;" p[top] ";48;" p[bot] "m▀" esc "[0m"
    }
    BEGIN { split(pal, p, " ") }
    NR % 2 == 1 { top = $0; next }
    {
      line = "  "
      for (i = 1; i <= length(top); i++) line = line cell(substr(top, i, 1), substr($0, i, 1))
      row = NR / 2
      if (row == 3) line = line "   " t1
      if (row == 4) line = line "   " t2
      if (row == 5) line = line "   " t3
      print line
    }' <<'EOF'
.......1111122334.......
.....11111112233445.....
....1111111122334456....
...211146666666664566...
...21466........66666...
...266............666...
...56..............66...
...66..............66...
...666............266...
...66654........11266...
...666544332111111266...
....6654433211111166....
.....66643321111566.....
.......6666666666.......
EOF
}

help_flag() {
  # help_flag FLAGS DESCRIPTION [ENV]
  printf '  %s\n          %s\n' "$(bold "$1")" "$2"
  [ -z "${3:-}" ] || printf '          %s\n' "$(faint "[env: $3]")"
}

print_help() {
  banner
  printf '%s\n' "$(bold 'USAGE')"
  printf '  curl -fsSL https://get.purpleclay.io | sh -s -- [FLAGS] <PRODUCT>\n\n'

  printf '%s\n' "$(bold 'ARGUMENTS')"
  printf '  %s\n          %s\n\n' "$(bold '<PRODUCT>')" "The purpleclay tool to install, e.g. nsv"

  printf '%s\n' "$(bold 'FLAGS')"
  help_flag "-v, --version <VERSION>" "Install a specific version, e.g. 1.2.3 or v1.2.3 [default: latest]" "PURPLECLAY_VERSION"
  help_flag "-d, --dir <DIR>" "Directory to install into [default: ~/.local/bin, or /usr/local/bin as root]" "PURPLECLAY_DIR"
  help_flag "    --debug" "Print debug output" "PURPLECLAY_DEBUG"
  help_flag "    --no-color" "Disable colour" "NO_COLOR"
  help_flag "-h, --help" "Print this help"
}

# ---------------------------------------------------------------------------
# Configuration and arguments. Flags override environment variables.
# ---------------------------------------------------------------------------

init_config() {
  OPT_VERSION="${PURPLECLAY_VERSION:-}"
  OPT_DIR="${PURPLECLAY_DIR:-}"
  OPT_DEBUG="${PURPLECLAY_DEBUG:-false}"
  OPT_NO_COLOR=false
  OPT_HELP=false
  PRODUCT=""
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help) OPT_HELP=true ;;
      -v | --version)
        [ $# -ge 2 ] || die "The $1 flag needs a value" "Run with --help to see usage"
        OPT_VERSION="$2"
        shift
        ;;
      -d | --dir)
        [ $# -ge 2 ] || die "The $1 flag needs a value" "Run with --help to see usage"
        OPT_DIR="$2"
        shift
        ;;
      --debug) OPT_DEBUG=true ;;
      --no-color) OPT_NO_COLOR=true ;;
      -*) die "Unknown flag '$1'" "Run with --help to see the available flags" ;;
      *)
        [ -z "$PRODUCT" ] || die "Only one product can be installed at a time" "Run with --help to see usage"
        PRODUCT="$1"
        ;;
    esac
    shift
  done
}

# check_args: the product and version are put into URLs, so only allow
# characters that can't change what those URLs point at.
check_args() {
  [ -n "$PRODUCT" ] || die "No product was given" \
    "Usage: curl -fsSL https://get.purpleclay.io | sh -s -- <product>" \
    "Run with --help to see usage"

  case "$PRODUCT" in
    *[!a-z0-9-]*) die "The product name '$PRODUCT' isn't valid" "Product names contain only a-z, 0-9 and '-'" ;;
  esac

  if [ -n "$OPT_VERSION" ] &&
    ! printf '%s\n' "$OPT_VERSION" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'; then
    die "The version '$OPT_VERSION' isn't valid" "Use a semantic version such as 1.2.3 or v1.2.3"
  fi

  [ -n "$OPT_DIR" ] || default_dir
  # An absolute path, so it can be compared with PATH and its parents found
  case "$OPT_DIR" in
    /) ;;
    /*) OPT_DIR="${OPT_DIR%/}" ;;
    *) OPT_DIR="$PWD/${OPT_DIR%/}" ;;
  esac
  # As given, before root resolves any links, for comparing with PATH
  DIR_GIVEN="$OPT_DIR"
}

# ---------------------------------------------------------------------------
# Platform
# ---------------------------------------------------------------------------

# detect_platform: sets OS (linux or darwin) and ARCH (x86_64 or arm64).
detect_platform() {
  _os=$(uname -s)
  _arch=$(uname -m)
  debug "uname reported $_os $_arch"

  case "$_os" in
    Linux) OS=linux ;;
    Darwin) OS=darwin ;;
    *) die "The operating system $_os ($_arch) isn't supported" "Prebuilt binaries are available for Linux and macOS" ;;
  esac
  case "$_arch" in
    x86_64 | amd64) ARCH=x86_64 ;;
    aarch64 | arm64) ARCH=arm64 ;;
    *) die "The architecture $_arch ($_os) isn't supported" "Prebuilt binaries are available for x86_64 and arm64" ;;
  esac

  # An x86_64 shell running under Rosetta on Apple silicon should still get
  # the native arm64 build.
  if [ "$OS" = darwin ] && [ "$ARCH" = x86_64 ] &&
    [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = 1 ]; then
    debug "The shell runs under Rosetta, so the native arm64 build is used"
    ARCH=arm64
  fi
}

# ---------------------------------------------------------------------------
# Requests. Only the response headers are needed to resolve a release, so no
# files are downloaded yet.
# ---------------------------------------------------------------------------

GITHUB_URL="https://github.com"
GITHUB_OWNER="purpleclay"

# init_downloader: use curl if it's installed, otherwise wget, and set the
# options every request uses. Without timeouts a stalled connection would hang
# the installer: curl has no time limit by default, and GNU wget retries 20
# times. An overall limit suits only small requests, so request adds one to
# HEAD requests and not to downloads.
init_downloader() {
  if have curl; then
    DOWNLOADER=curl
    DOWNLOADER_OPTS="--proto =https --tlsv1.2 --connect-timeout 10 --retry 2"
  elif have wget; then
    DOWNLOADER=wget
    DOWNLOADER_OPTS="-T 15"
    _wget_help=$(wget --help 2>&1)
    # busybox wget, the only wget on Alpine, has neither --tries nor
    # --https-only. Where redirects can't be limited to HTTPS, the redirect
    # target is checked instead.
    case "$_wget_help" in *--tries*) DOWNLOADER_OPTS="$DOWNLOADER_OPTS -t 2" ;; esac
    case "$_wget_help" in *--https-only*) DOWNLOADER_OPTS="$DOWNLOADER_OPTS --https-only" ;; esac
  else
    die "Neither curl nor wget is installed" "Install one of them, then try again"
  fi
  debug "Requests use $DOWNLOADER $DOWNLOADER_OPTS"
}

# request URL [FILE]: sets STATUS and LOCATION from the response headers.
# Without FILE it's a HEAD request. With FILE, redirects are followed and the
# body is saved to FILE. When github.com couldn't be reached, STATUS is empty
# and NET_ERROR holds the downloader's exit code and message. A HEAD request
# with curl reports the first response; otherwise redirects are followed, so
# the last status and Location seen are reported.
request() {
  _rc=0
  if [ "$DOWNLOADER" = curl ] && [ $# -eq 2 ]; then
    # --proto applies only to the first request, so redirects are limited to
    # HTTPS separately. -D - prints every response's headers. A stalled
    # download is stopped, rather than one that is only slow, so large files
    # aren't cut off.
    # shellcheck disable=SC2086 # DOWNLOADER_OPTS holds whole flags only
    _out=$(curl -sS -L --proto-redir =https -D - -o "$2" $DOWNLOADER_OPTS --speed-limit 1 --speed-time 30 "$1" 2>&1) || _rc=$?
  elif [ "$DOWNLOADER" = curl ]; then
    # shellcheck disable=SC2086
    _out=$(curl -sS -I --max-time 30 $DOWNLOADER_OPTS "$1" 2>&1) || _rc=$?
  else
    if [ $# -eq 2 ]; then
      # shellcheck disable=SC2086
      _out=$(wget -S -O "$2" $DOWNLOADER_OPTS "$1" 2>&1) || _rc=$?
    else
      # shellcheck disable=SC2086
      _out=$(wget -S --spider $DOWNLOADER_OPTS "$1" 2>&1) || _rc=$?
    fi
    # busybox wget built with its own TLS, rather than Alpine's ssl_client,
    # accepts any certificate. Releases could then be swapped in transit,
    # checksums included, so stop before anything it returned is used.
    case "$_out" in
      *"certificate validation not implemented"*)
        die "This wget can't verify TLS certificates, so it isn't safe to use" \
          "Install curl, or a wget that verifies certificates, then try again"
        ;;
    esac
  fi
  _out=$(printf '%s\n' "$_out" | tr -d '\r')
  STATUS=$(printf '%s\n' "$_out" | awk '$1 ~ /^HTTP\// { s = $2 } END { print s }')
  LOCATION=$(printf '%s\n' "$_out" | awk 'tolower($1) == "location:" { l = $2 } END { print l }')

  # curl only fails on a network error, as it's run without -f.
  # wget also fails on an HTTP error, which ends on a 4xx or 5xx status. As
  # wget follows redirects, failing after any other status means a redirect
  # target couldn't be reached.
  _failed=false
  if [ "$_rc" -ne 0 ]; then
    case "$DOWNLOADER:$STATUS" in
      wget:4?? | wget:5??) ;;
      *) _failed=true ;;
    esac
  fi
  NET_ERROR=""
  if [ -z "$STATUS" ] || [ "$_failed" = true ]; then
    NET_STATUS="$STATUS" NET_RC="$_rc" STATUS="" LOCATION=""
    NET_ERROR=$(printf '%s\n' "$_out" | awk '/^curl: \([0-9]+\)/ { c = $0 } /^(curl|wget): / || / failed: / { e = $0 } END { print (c != "" ? c : e) }')
  fi

  # Shown relative to the repository, to keep debug output short. The
  # repository's own URL is shown once, by resolve_tag.
  _repo="$GITHUB_URL/$GITHUB_OWNER/$PRODUCT"
  _method=HEAD
  [ $# -lt 2 ] || _method=GET
  if [ -z "$STATUS" ]; then
    debug "$_method ${1#"$_repo"} failed with exit code $_rc${NET_ERROR:+: $NET_ERROR}"
  elif [ $# -lt 2 ]; then
    debug "HEAD ${1#"$_repo"} returned $STATUS${LOCATION:+, redirecting to ${LOCATION#"$_repo"}}"
  else
    # Downloads redirect to signed URLs, which mustn't end up in a bug
    # report, so only the host is shown.
    _host="${LOCATION#*://}"
    debug "GET ${1#"$_repo"} returned $STATUS${LOCATION:+ from ${_host%%/*}}"
  fi
}

# download URL FILE: save URL to FILE. Returns once STATUS is 200 or 404, and
# stops with a clear reason otherwise.
download() {
  request "$1" "$2"
  check_status
  case "$LOCATION" in
    "" | https://*) ;;
    *) die "The download was redirected to $LOCATION, which isn't HTTPS" ;;
  esac
  case "$STATUS" in
    200 | 404) ;;
    *) die "Got an unexpected response from github.com (HTTP $STATUS)" ;;
  esac
}

# check_status: stop with a clear reason for anything other than success, a
# redirect or 404, which each caller handles itself.
check_status() {
  case "$STATUS" in
    "") unreachable ;;
    2?? | 3?? | 404) ;;
    429) die "github.com is limiting requests from your network" "Wait a few minutes, then try again" ;;
    403) die "github.com refused the request (HTTP 403)" "If you're behind a proxy or firewall, check that it allows github.com" ;;
    5??) die "github.com returned a server error (HTTP $STATUS)" "GitHub may be having problems" "Check https://www.githubstatus.com, then try again" ;;
    *) die "Got an unexpected response from github.com (HTTP $STATUS)" ;;
  esac
}

# ---------------------------------------------------------------------------
# Release tags
# ---------------------------------------------------------------------------

# resolve_tag: sets TAG for PRODUCT, from OPT_VERSION or the latest release.
# Uses github.com redirects rather than the GitHub API, which allows only 60
# requests an hour without a token.
resolve_tag() {
  _repo="$GITHUB_URL/$GITHUB_OWNER/$PRODUCT"
  debug "Releases are read from $_repo"
  if [ -z "$OPT_VERSION" ]; then
    resolve_latest_tag "$_repo"
  else
    resolve_version_tag "$_repo"
  fi
}

resolve_latest_tag() {
  request "$1/releases/latest"
  check_status
  [ "$STATUS" != 404 ] || not_found
  case "$LOCATION" in
    "$1/releases/tag/"*)
      TAG="${LOCATION#"$1/releases/tag/"}"
      case "$TAG" in
        "" | *[!0-9A-Za-z.+-]*) unexpected_response ;;
      esac
      ;;
    "$1/releases") die "There are no releases of $PRODUCT yet" "See $1 for other ways to install it" ;;
    *) unexpected_response ;;
  esac
}

# Rust releases are tagged 1.2.3 and Go releases v1.2.3; accept either, so
# users don't need to know which.
resolve_version_tag() {
  case "$OPT_VERSION" in
    v*) _other="${OPT_VERSION#v}" ;;
    *) _other="v$OPT_VERSION" ;;
  esac
  for TAG in "$OPT_VERSION" "$_other"; do
    request "$1/releases/tag/$TAG"
    check_status
    [ "$STATUS" != 200 ] || return 0
  done

  # Neither tag exists. Check the product does, for a clearer error.
  request "$1/releases/latest"
  check_status
  [ "$STATUS" != 404 ] || not_found
  die "There is no release $OPT_VERSION of $PRODUCT" "See $1/releases for the available versions"
}

not_found() {
  die "Couldn't find $PRODUCT" "Check that $GITHUB_URL/$GITHUB_OWNER/$PRODUCT exists"
}

# unreachable: explain why github.com couldn't be reached, from the
# downloader's exit code. Shown without --debug, as it's what people need to
# fix the problem themselves.
unreachable() {
  _hint="Check your network connection, then try again"
  if [ "$DOWNLOADER" = curl ]; then
    case "$NET_RC" in
      5) _why="your proxy's address couldn't be found" _hint="Check your proxy settings, such as HTTPS_PROXY" ;;
      6) _why="its address couldn't be found" ;;
      7) _why="the connection was refused" ;;
      28) _why="the request timed out" ;;
      35) _why="a secure connection couldn't be set up" ;;
      56)
        _why="the connection was closed unexpectedly"
        [ "$NET_STATUS" != 407 ] || _why="your proxy needs you to sign in (HTTP 407)"
        _hint="If you're behind a proxy, check your proxy settings, such as HTTPS_PROXY"
        ;;
      60)
        _why="its certificate couldn't be verified"
        _hint="If you're behind a proxy that inspects HTTPS, point CURL_CA_BUNDLE at its certificate"
        ;;
      *) _why="curl failed with exit code $NET_RC" ;;
    esac
  else
    case "$NET_RC" in
      4) _why="the network request failed" ;;
      5) _why="its certificate couldn't be verified" ;;
      *) _why="wget failed with exit code $NET_RC" ;;
    esac
  fi
  die "Couldn't reach github.com: $_why" "$_hint" "Run with --debug for details"
}

unexpected_response() {
  die "Got an unexpected response from github.com" "It redirected to ${LOCATION:-nowhere}"
}

# ---------------------------------------------------------------------------
# Archives and checksums
# ---------------------------------------------------------------------------

# init_workdir: sets WORK to a temporary directory, removed when the
# installer exits, whether it succeeded or not.
init_workdir() {
  WORK=$(mktemp -d) || die "Couldn't create a temporary directory" "Check that TMPDIR, or /tmp, is writable"
  trap cleanup EXIT
  # A signal doesn't run the EXIT trap in every shell, but exit does
  trap 'exit 1' HUP INT TERM
  debug "Downloads are saved to $WORK"
}

# cleanup: remove the downloads, and a binary staged in the install directory
# but not yet renamed into place, such as when the install is interrupted.
cleanup() {
  rm -rf "$WORK"
  [ -z "${STAGED:-}" ] || rm -f "$STAGED"
}

# fetch_checksums: downloads the release's checksums.txt to WORK.
fetch_checksums() {
  _repo="$GITHUB_URL/$GITHUB_OWNER/$PRODUCT"
  download "$_repo/releases/download/$TAG/checksums.txt" "$WORK/checksums.txt"
  [ "$STATUS" != 404 ] || die "Release $TAG of $PRODUCT has no checksums.txt, so it can't be verified" \
    "It was published before the installer could verify downloads" \
    "See $_repo#install for other ways to install it"
}

# select_asset: sets ASSET and ASSET_SHA to the one archive in checksums.txt
# built for this platform. An archive matches when its name starts with the
# product and holds an OS and an architecture as whole words, separated by
# - _ or . from the rest, so a part of a word never matches.
select_asset() {
  case "$ARCH" in
    x86_64) _arch='x86_64|amd64' ;;
    arm64) _arch='arm64|aarch64' ;;
  esac
  # Names are checked before they're put into a URL or path
  _archives=$(awk -v p="$PRODUCT" '
    { f = $2; sub(/^\*/, "", f) }
    length($1) == 64 && $1 !~ /[^0-9A-Fa-f]/ && f ~ /^[0-9A-Za-z._+-]+\.tar\.gz$/ &&
      index(f, p) == 1 && substr(f, length(p) + 1, 1) ~ /[-_]/ { print tolower($1), f }
  ' "$WORK/checksums.txt")
  _matches=$(printf '%s\n' "$_archives" | awk -v os="$OS" -v arch="$_arch" '
    $2 ~ ("(^|[-_.])(" os ")([-_.]|$)") && $2 ~ ("(^|[-_.])(" arch ")([-_.]|$)")')

  case $(printf '%s' "$_matches" | awk 'END { print NR }') in
    0)
      if [ -n "$_archives" ]; then
        die "There is no build for $OS/$ARCH in release $TAG of $PRODUCT" "The release has these archives:" \
          "$(printf '%s\n' "$_archives" | awk '{ print "  " $2 }')"
      fi
      die "There is no build for $OS/$ARCH in release $TAG of $PRODUCT" \
        "Its checksums.txt lists no .tar.gz archives of $PRODUCT"
      ;;
    1) ;;
    *)
      die "More than one build matches $OS/$ARCH in release $TAG of $PRODUCT" "It's not clear which of these to install:" \
        "$(printf '%s\n' "$_matches" | awk '{ print "  " $2 }')"
      ;;
  esac
  ASSET_SHA="${_matches%% *}"
  ASSET="${_matches#* }"
  debug_pair Selected "$ASSET"
  debug_pair "Expected SHA-256" "$ASSET_SHA"
}

download_asset() {
  ARCHIVE="$WORK/$ASSET"
  download "$GITHUB_URL/$GITHUB_OWNER/$PRODUCT/releases/download/$TAG/$ASSET" "$ARCHIVE"
  [ "$STATUS" != 404 ] || die "Couldn't download $ASSET (HTTP 404)" \
    "Release $TAG of $PRODUCT lists it in checksums.txt, but doesn't include it"
}

# verify_checksum: the archive's SHA-256 must match checksums.txt. There's
# deliberately no way to skip this.
verify_checksum() {
  if have sha256sum; then
    _tool=sha256sum _sum=$(sha256sum "$ARCHIVE" | awk '{ print $1 }')
  elif have shasum; then
    _tool=shasum _sum=$(shasum -a 256 "$ARCHIVE" | awk '{ print $1 }')
  elif have openssl; then
    _tool=openssl _sum=$(openssl dgst -sha256 "$ARCHIVE" | awk '{ print $NF }')
  else
    die "There is no tool to compute a SHA-256 checksum with" "Install sha256sum, shasum or openssl, then try again"
  fi
  _sum=$(printf '%s' "$_sum" | tr 'A-F' 'a-f')
  debug_pair "Computed with" "$_tool"
  debug_pair "Actual SHA-256" "$_sum"
  [ -n "$_sum" ] || die "$_tool couldn't compute the checksum of $ASSET"

  if [ "$_sum" != "$ASSET_SHA" ]; then
    rm -f "$ARCHIVE"
    die "The checksum of $ASSET doesn't match checksums.txt" \
      "Expected $ASSET_SHA" \
      "Got      $_sum" \
      "The download may be corrupt or tampered with, so it was deleted"
  fi
}

# ---------------------------------------------------------------------------
# Installing
# ---------------------------------------------------------------------------

# extract_binary: sets BINARY to the product's binary, found at the top of
# the archive or inside a single directory.
extract_binary() {
  _dir="$WORK/extract"
  if ! mkdir "$_dir" || ! _err=$(tar -xzf "$ARCHIVE" -C "$_dir" 2>&1); then
    debug "tar reported: ${_err:-nothing}"
    die "Couldn't extract $ASSET" "Run with --debug for details"
  fi

  BINARY="" _count=0
  for _file in "$_dir/$PRODUCT" "$_dir"/*/"$PRODUCT"; do
    [ -f "$_file" ] || continue
    BINARY="$_file" _count=$((_count + 1))
  done
  _report="Report this at $GITHUB_URL/$GITHUB_OWNER/$PRODUCT/issues"
  [ "$_count" -gt 0 ] || die "$ASSET doesn't contain the $PRODUCT binary" "$_report"
  [ "$_count" -eq 1 ] || die "$ASSET contains more than one $PRODUCT binary" "$_report"
  debug "Found ${BINARY#"$_dir/"} in $ASSET"
}

# default_dir: sets OPT_DIR to where to install without --dir. Root installs
# for everyone, anyone else into their own ~/.local/bin, where the XDG base
# directory specification puts a user's programs. The installer never asks
# for more privileges than it runs with.
default_dir() {
  if [ "$(id -u)" = 0 ]; then
    OPT_DIR=/usr/local/bin
  elif [ -n "${HOME:-}" ]; then
    OPT_DIR="$HOME/.local/bin"
  else
    die "HOME isn't set, so there's no default directory to install into" "Choose one with --dir"
  fi
}

# check_writable: the install directory, or its nearest parent that exists
# when it needs creating, must be writable.
check_writable() {
  _dir="$OPT_DIR"
  while [ ! -d "$_dir" ]; do
    _dir="${_dir%/*}"
    [ -n "$_dir" ] || _dir=/
  done
  [ -w "$_dir" ] || die "$_dir isn't writable, so $PRODUCT can't be installed into $OPT_DIR" \
    "Choose a directory you can write to with --dir, or run the installer as root"
}

# check_root_owned: as root, stop unless only root can change the install
# directory and every directory above it. Otherwise another user could swap a
# directory for a link, so root writes somewhere they chose, or replace the
# binary root has just installed. A parent with the sticky bit, such as /tmp,
# is fine, as other users can't rename what root owns there.
check_root_owned() {
  [ "$(id -u)" = 0 ] || return 0
  # Directories root creates must be root's alone, whatever umask it was given
  umask 022
  _dir="$OPT_DIR"
  while [ ! -d "$_dir" ]; do
    _dir="${_dir%/*}"
    [ -n "$_dir" ] || _dir=/
  done
  case "$_dir" in
    /) _missing="$OPT_DIR" ;;
    *) _missing="${OPT_DIR#"$_dir"}" ;;
  esac
  # Only directories that exist can be checked, so the part still to be
  # created mustn't lead back out of them
  case "$_missing/" in
    */./* | */../*)
      die "$DIR_GIVEN uses . or .. in a part that doesn't exist yet, so where it leads can't be checked" \
        "Give the directory without . or .., then try again"
      ;;
  esac
  # Check where it really is: through a symlink, the directories above the
  # target matter, not the ones above the link. Root then writes through the
  # path that was checked, so a link can't be changed afterwards to point
  # somewhere else.
  _dir=$(cd -P "$_dir" && pwd -P) || die "Couldn't resolve $OPT_DIR" "Check the path, then try again"
  OPT_DIR="${_dir%/}$_missing"
  [ -n "$OPT_DIR" ] || OPT_DIR=/

  _parent=false
  while :; do
    # shellcheck disable=SC2046 # split ls into fields: mode, links, owner
    set -- $(ls -ldn "$_dir")
    _unsafe=false
    [ "$3" = 0 ] || _unsafe=true
    case "$1" in
      ?????w* | ????????w*)
        case "$_parent:$1" in
          true:?????????[tT]*) ;;
          *) _unsafe=true ;;
        esac
        ;;
    esac
    if [ "$_unsafe" = true ]; then
      die "$_dir can be changed by users other than root, so installing into $DIR_GIVEN as root isn't safe" \
        "Install into a directory only root can change, such as /usr/local/bin, or run the installer as a normal user"
    fi

    [ "$_dir" != / ] || return 0
    _dir="${_dir%/*}"
    [ -n "$_dir" ] || _dir=/
    _parent=true
  done
}

# install_binary: install BINARY into the install directory, creating it if
# needed. It's installed under a temporary name, then renamed over any older
# copy, so an upgrade never leaves a half-written binary and works even while
# the old one is running.
install_binary() {
  # mv would move the binary inside a directory rather than replace it
  [ ! -d "$OPT_DIR/$PRODUCT" ] ||
    die "$OPT_DIR/$PRODUCT is a directory, so $PRODUCT can't be installed there" "Move or remove it, then try again"

  check_root_owned
  check_writable
  mkdir -p "$OPT_DIR" || die "Couldn't create $OPT_DIR" "Check the path, then try again"
  STAGED="$OPT_DIR/.$PRODUCT.install.$$"
  if ! install -m 755 "$BINARY" "$STAGED" || ! mv -f "$STAGED" "$OPT_DIR/$PRODUCT"; then
    die "Couldn't install $PRODUCT into $OPT_DIR" "Run with --debug for details"
  fi
  STAGED=""
}

# check_version: before anything is installed, the verified binary must report
# the version being installed. It runs from the private temporary directory,
# by its full path, so nobody else can swap it and another copy on PATH can't
# answer. A failed check leaves any installed copy alone. Every purpleclay
# tool answers to --version or -V.
check_version() {
  _want="${TAG#v}"
  # Tells a temporary directory mounted noexec apart from a broken binary
  printf '#!/bin/sh\n' >"$WORK/probe" && chmod 755 "$WORK/probe" "$BINARY"
  "$WORK/probe" 2>/dev/null ||
    die "Programs can't be run from $WORK, so the version of $PRODUCT can't be checked" \
      "Set TMPDIR to a directory that allows running programs, then try again"

  _out=$("$BINARY" --version </dev/null 2>&1) ||
    _out=$("$BINARY" -V </dev/null 2>&1) || _out=""
  _first=$(printf '%s\n' "$_out" | awk 'NR == 1')
  debug "$PRODUCT reported: ${_first:-nothing}"
  # A whole word of the output must be the version, with or without a v, so
  # 0.12.2 isn't mistaken for 0.12.20 or 10.12.2
  if ! printf '%s\n' "$_out" | awk -v want="$_want" '
    {
      n = split($0, words, "[^0-9A-Za-z.+-]+")
      for (i = 1; i <= n; i++) {
        word = words[i]
        sub(/^v/, "", word)
        if (word == want) found = 1
      }
    }
    END { exit !found }'; then
    die "$ASSET reports ${_first:-nothing} rather than version $_want" \
      "Report this at $GITHUB_URL/$GITHUB_OWNER/$PRODUCT/issues"
  fi
}

warn_if_not_on_path() {
  # PATH may name the directory with a trailing slash, or as given rather than
  # resolved
  case ":$PATH:" in
    *":$OPT_DIR:"* | *":$OPT_DIR/:"* | *":$DIR_GIVEN:"* | *":$DIR_GIVEN/:"*) ;;
    *)
      warn "$OPT_DIR isn't on your PATH, so run $PRODUCT with its full path" \
        "Add it to PATH in your shell's profile, then open a new terminal, to run $PRODUCT by name"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  set -u
  init_config

  # Look for --no-color first, so errors raised while parsing the other
  # arguments honour it wherever it appears.
  for _arg in "$@"; do
    [ "$_arg" != "--no-color" ] || OPT_NO_COLOR=true
  done
  init_style 2
  parse_args "$@"

  if is_true "$OPT_HELP"; then
    init_style 1
    print_help
    exit 0
  fi

  check_args

  banner >&2
  debug_context

  begin Detecting "the host platform"
  detect_platform
  done_step Detected "the host platform as $OS/$ARCH"

  if [ -n "$OPT_VERSION" ]; then
    begin Resolving "release $OPT_VERSION of $PRODUCT"
  else
    begin Resolving "the latest release of $PRODUCT"
  fi
  init_downloader
  resolve_tag
  if [ -n "$OPT_VERSION" ]; then
    done_step Resolved "release $TAG of $PRODUCT"
  else
    done_step Resolved "the latest release of $PRODUCT as $TAG"
  fi

  begin Downloading "the $OS/$ARCH build of $PRODUCT $TAG"
  init_workdir
  fetch_checksums
  select_asset
  download_asset
  done_step Downloaded "$ASSET"

  begin Verifying "the checksum of $ASSET"
  verify_checksum
  done_step Verified "the checksum of $ASSET"

  begin Checking "the version $PRODUCT reports"
  extract_binary
  check_version
  done_step Checked "$PRODUCT reports version ${TAG#v}"

  begin Installing "$PRODUCT $TAG into $OPT_DIR"
  install_binary
  done_step Installed "$PRODUCT $TAG into $OPT_DIR"

  warn_if_not_on_path
}

main "$@"
