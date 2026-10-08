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

INSTALLER_VERSION="0.1.0"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

is_true() {
  case "$1" in
    1 | true | TRUE | True | yes | YES | on | ON) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Styling. All escape codes are built here, so the call sites never change
# when the brand theme is applied.
# ---------------------------------------------------------------------------

# init_style FD: colour only when FD is a terminal and NO_COLOR is unset.
init_style() {
  ESC=$(printf '\033')
  COLOR=false
  if [ -z "${NO_COLOR:-}" ] && ! is_true "$OPT_NO_COLOR" && [ -t "$1" ]; then
    COLOR=true
  fi
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
# ---------------------------------------------------------------------------

log() { printf '%s %s\n' "$1" "$2" >&2; }

info() { log "$(style 36 'info ')" "$*"; }
warn() { log "$(style 33 'warn ')" "$*"; }
error() { log "$(style 31 'error')" "$*"; }

debug() {
  is_true "$OPT_DEBUG" || return 0
  log "$(faint 'debug')" "$(faint "$*")"
}

# die MESSAGE [HINT...]
die() {
  error "$1"
  shift
  for _hint in "$@"; do
    log '     ' "$_hint"
  done
  exit 1
}

# ---------------------------------------------------------------------------
# Banner and help
# ---------------------------------------------------------------------------

banner() {
  _title=$(bold "$(purple 50 'purpleclay')")
  _tagline="One script to install them all"
  _version=$(faint "install.sh $INSTALLER_VERSION")

  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8* | *utf-8* | *UTF8* | *utf8*) _utf8=true _sep='·' ;;
    *) _utf8=false _sep='-' ;;
  esac

  # The ring needs colour and UTF-8. Without them, which mostly means CI logs,
  # piped output and minimal containers, a single line is enough.
  printf '\n'
  if [ "$COLOR" = true ] && [ "$_utf8" = true ]; then
    ring "$_title" "$_tagline" "$_version"
  else
    printf '%s %s %s %s %s\n' "$_title" "$_sep" "$_tagline" "$_sep" "$_version"
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
  help_flag "    --debug" "Print debug output" "PURPLECLAY_DEBUG"
  help_flag "    --no-color" "Disable colour" "NO_COLOR"
  help_flag "-h, --help" "Print this help"
}

# ---------------------------------------------------------------------------
# Configuration and arguments. Flags override environment variables.
# ---------------------------------------------------------------------------

init_config() {
  OPT_DEBUG="${PURPLECLAY_DEBUG:-false}"
  OPT_NO_COLOR=false
  OPT_HELP=false
  PRODUCT=""
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help) OPT_HELP=true ;;
      --debug) OPT_DEBUG=true ;;
      --no-color) OPT_NO_COLOR=true ;;
      -*) die "unknown flag '$1'" "Run with --help to see the available flags." ;;
      *)
        [ -z "$PRODUCT" ] || die "only one product can be installed at a time" "Run with --help to see usage."
        PRODUCT="$1"
        ;;
    esac
    shift
  done
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

  [ -n "$PRODUCT" ] || die "no product given" \
    "Usage: curl -fsSL https://get.purpleclay.io | sh -s -- <product>" \
    "Run with --help to see usage."

  banner >&2
  debug "installer $INSTALLER_VERSION, colour $COLOR"
  info "installing $PRODUCT"
  warn "downloads aren't supported yet, nothing was installed"
}

main "$@"
