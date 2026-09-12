#!/usr/bin/env bash
#===============================================================================
# install.sh : installer for pfwd (persistent SSH port forwarding)
#===============================================================================
# Install the latest released pfwd from GitHub:
#
#   curl -fsSL https://raw.githubusercontent.com/little-forest/port-forwarder/main/install.sh | bash
#
# Environment variables:
#   PFWD_INSTALL_DIR  destination directory
#                     (default: Linux /usr/local/bin, macOS ~/.local/bin)
#   PFWD_VERSION      git ref to install (default: the tag of the latest release)
#                     Set it to 'main' to install the development version.
#   NO_COLOR          disable colored output (https://no-color.org/)
#
# This script has to run under the bash 3.2 that ships with macOS, so none of
# the bash 4 features pfwd itself relies on (associative arrays, declare -g,
# ${var^^}, printf '%(%s)T') may be used here.
#===============================================================================

#-------------------------------------------------------------------------------
#- global variables ------------------------------------------------------------
#{{{
_REPO='little-forest/port-forwarder'
_BIN='pfwd'
_RAW_BASE="https://raw.githubusercontent.com/${_REPO}"
_API_LATEST="https://api.github.com/repos/${_REPO}/releases/latest"

_OS=$(uname)
_DOWNLOADER=
_TMP_DIR=
_INSTALL_DIR=
_REF=

# colors (assigned in __setup_color)
C_OFF=
C_GREEN=
C_YELLOW=
C_RED=
C_CYAN=
#}}}

#-------------------------------------------------------------------------------
#- common functions ------------------------------------------------------------
#{{{
# Emit ANSI SGR sequences directly, matching pfwd's __setup_color.
# Colors are keyed off stdout because stdin is the script itself when this
# installer is run as 'curl ... | bash', so a tty test on stdin never passes.
__setup_color() { #{{{
  local ESC=$'\033'

  [[ -t 1 ]] || return 0
  # terminals that cannot show color
  case "${TERM:-dumb}" in
    dumb|*-mono|vt100|vt102|vt220) return 0 ;;
  esac
  # https://no-color.org/
  [[ -n "${NO_COLOR}" ]] && return 0

  C_OFF="${ESC}[0m"
  C_GREEN="${ESC}[32m"
  C_YELLOW="${ESC}[93m"
  C_RED="${ESC}[91m"
  C_CYAN="${ESC}[36m"
  return 0
}
#}}}

__show_ok() { #{{{
  printf '[%s  OK  %s] %s\n' "$C_GREEN" "$C_OFF" "$*"
}
#}}}

__show_info() { #{{{
  printf '%s%s%s\n' "$C_CYAN" "$*" "$C_OFF"
}
#}}}

__show_warn() { #{{{
  printf '[%s WARN %s] %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2
}
#}}}

__show_error() { #{{{
  printf '[%s ERROR %s] %s\n' "$C_RED" "$C_OFF" "$*" >&2
}
#}}}

__error_end() { #{{{
  __show_error "$*"
  exit 1
}
#}}}

__cleanup() { #{{{
  [[ -n "$_TMP_DIR" && -d "$_TMP_DIR" ]] && rm -rf "$_TMP_DIR"
  return 0
}
#}}}
#}}}

#-------------------------------------------------------------------------------
#- error messages --------------------------------------------------------------
#{{{
# Continuation lines are indented by 9 characters to line up under the
# '[ ERROR ] ' / '[ WARN ] ' prefix.
_err_no_downloader() { #{{{
  printf 'neither curl nor wget is available\n'
  printf '         install one of them and run this installer again'
}
#}}}

_err_no_release() { #{{{
  printf 'could not determine the latest release of %s\n' "$_REPO"
  printf '         the repository may have no release yet, or the GitHub API is unreachable\n'
  printf '         to install the development version, set PFWD_VERSION=main'
}
#}}}

_err_download_failed() { #{{{
  printf 'failed to download %s\n' "$1"
  printf "         check your network connection and that the ref '%s' exists" "$2"
}
#}}}

_err_verify_failed() { #{{{
  case "$1" in
    1) printf 'the downloaded file is empty' ;;
    2) printf 'the downloaded file is not a %s script (unexpected shebang)' "$_BIN" ;;
    3) printf 'the downloaded file does not look like %s (no _VERSION found)' "$_BIN" ;;
    *) printf 'the downloaded file is not valid bash (the download was probably truncated)' ;;
  esac
  printf '\n         retry the installation; if it keeps failing, please report it at\n'
  printf '         https://github.com/%s/issues' "$_REPO"
}
#}}}

_err_no_permission() { #{{{
  printf 'no write permission for %s and sudo is not available\n' "$1"
  printf '         install it manually, or choose a writable directory:\n'
  # SC2016: the command line is shown to the user verbatim; $HOME must not expand here
  # shellcheck disable=SC2016
  printf '         PFWD_INSTALL_DIR=$HOME/.local/bin'
}
#}}}

_err_install_failed() { #{{{
  printf 'failed to install %s into %s' "$_BIN" "$1"
}
#}}}

_err_old_bash() { #{{{
  printf 'bash %s found on PATH, but %s requires bash 4.2 or later\n' "$1" "$_BIN"
  printf '         macOS : brew install bash\n'
  printf '         Linux : install a newer bash from your distribution'
}
#}}}

_err_no_ssh() { #{{{
  printf "required command 'ssh' not found\n"
  printf '         macOS : it ships with the OS; check your PATH\n'
  printf '         Linux : sudo dnf install openssh-clients'
}
#}}}

_err_no_yq() { #{{{
  printf "required command 'yq' not found\n"
  printf '         macOS : brew install yq\n'
  printf '         Linux : https://github.com/mikefarah/yq/releases'
}
#}}}

_err_wrong_yq() { #{{{
  printf "the 'yq' on PATH is not mikefarah/yq v4 (%s)\n" "$1"
  printf '         the same-named Python tool will not work\n'
  printf '         see https://github.com/mikefarah/yq/releases'
}
#}}}

_err_not_in_path() { #{{{
  local RC
  # SC2088: these are file names shown to the user, never passed to the shell,
  # so '~' is the right thing to print
  # shellcheck disable=SC2088
  case "${SHELL##*/}" in
    zsh)  RC='~/.zshrc' ;;
    bash) RC='~/.bashrc' ;;
    *)    RC='your shell startup file' ;;
  esac
  printf '%s is not in your PATH\n' "$1"
  printf '         add the following line to %s:\n' "$RC"
  # SC2016: the line is shown to the user verbatim; $PATH must not expand here
  # shellcheck disable=SC2016
  printf '           export PATH="%s:$PATH"' "$1"
}
#}}}
#}}}

#-------------------------------------------------------------------------------
#- download --------------------------------------------------------------------
#{{{
# pick the download command; curl is preferred because this installer is
# normally piped from curl in the first place
_detect_downloader() { #{{{
  if command -v curl >/dev/null 2>&1; then
    _DOWNLOADER=curl
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    _DOWNLOADER=wget
    return 0
  fi
  return 1
}
#}}}

# --proto '=https' rejects a redirect that downgrades to plain http.
# --tlsv1.2 is deliberately omitted: it is unsupported by curl older than
# 7.34, and GitHub refuses anything below TLS 1.2 anyway.
_fetch_stdout() { #{{{
  local URL=$1
  case "$_DOWNLOADER" in
    curl) curl -fsSL --proto '=https' "$URL" 2>/dev/null ;;
    wget) wget -q -O - "$URL" 2>/dev/null ;;
    *)    return 1 ;;
  esac
}
#}}}

_fetch_file() { #{{{
  local URL=$1 DEST=$2
  case "$_DOWNLOADER" in
    curl) curl -fsSL --proto '=https' -o "$DEST" "$URL" 2>/dev/null ;;
    wget) wget -q -O "$DEST" "$URL" 2>/dev/null ;;
    *)    return 1 ;;
  esac
}
#}}}

# print the tag name of the latest release. jq is not assumed, so the field is
# pulled out with grep/sed; a release-less repository answers with a JSON body
# that has no tag_name, which is reported as a failure
_latest_release_tag() { #{{{
  local JSON TAG
  JSON=$(_fetch_stdout "$_API_LATEST") || return 1
  TAG=$(printf '%s\n' "$JSON" \
    | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -n 1 \
    | sed -e 's/.*:[[:space:]]*"//' -e 's/"$//')
  [[ -z "$TAG" ]] && return 1
  printf '%s\n' "$TAG"
  return 0
}
#}}}

# decide which ref to install: PFWD_VERSION wins, otherwise the latest release.
# There is intentionally no fallback to main; installing an unreleased commit
# has to be an explicit choice.
_resolve_ref() { #{{{
  local TAG
  if [[ -n "${PFWD_VERSION}" ]]; then
    printf '%s\n' "$PFWD_VERSION"
    return 0
  fi
  TAG=$(_latest_release_tag) || return 1
  printf '%s\n' "$TAG"
  return 0
}
#}}}

# 0 = ok / 1 = empty / 2 = bad shebang / 3 = not pfwd / 4 = not valid bash.
# A truncated transfer is already rejected by curl -f / wget themselves (the
# body does not match Content-Length), so these checks are the second net: they
# catch a complete but wrong body, such as an error page from a proxy.
# pfwd parses cleanly even under bash 3.2, so bash -n with the current shell is
# safe here.
_verify() { #{{{
  local FILE=$1 LINE1
  [[ -s "$FILE" ]] || return 1
  LINE1=$(head -n 1 "$FILE")
  [[ "$LINE1" == '#!/usr/bin/env bash' ]] || return 2
  grep -q '^_VERSION=' "$FILE" || return 3
  bash -n "$FILE" 2>/dev/null || return 4
  return 0
}
#}}}

_read_version() { #{{{
  local FILE=$1
  grep -m 1 '^_VERSION=' "$FILE" \
    | sed -e 's/^_VERSION=//' -e "s/^'//" -e "s/'\$//"
}
#}}}
#}}}

#-------------------------------------------------------------------------------
#- install ---------------------------------------------------------------------
#{{{
_detect_install_dir() { #{{{
  if [[ -n "${PFWD_INSTALL_DIR}" ]]; then
    printf '%s\n' "$PFWD_INSTALL_DIR"
    return 0
  fi
  if [[ "$_OS" == 'Darwin' ]]; then
    printf '%s\n' "${HOME}/.local/bin"
  else
    printf '%s\n' '/usr/local/bin'
  fi
  return 0
}
#}}}

# writable either directly, or through the nearest existing ancestor when the
# directory still has to be created
_is_writable_dir() { #{{{
  local DIR=$1
  while [[ -n "$DIR" && ! -e "$DIR" ]]; do
    DIR=$(dirname "$DIR")
  done
  [[ -d "$DIR" && -w "$DIR" ]]
}
#}}}

# sudo reads its password from /dev/tty, so the prompt still works while this
# script is being piped into bash
_install_bin() { #{{{
  local SRC=$1 DIR=$2
  local -a CMD=()

  if ! _is_writable_dir "$DIR"; then
    if ! command -v sudo >/dev/null 2>&1; then
      __show_error "$(_err_no_permission "$DIR")"
      return 1
    fi
    __show_info "${DIR} is not writable; asking for sudo"
    CMD=(sudo)
  fi

  if [[ ! -d "$DIR" ]]; then
    "${CMD[@]}" mkdir -p "$DIR" || return 1
  fi
  "${CMD[@]}" install -m 755 "$SRC" "${DIR}/${_BIN}" || return 1
  return 0
}
#}}}
#}}}

#-------------------------------------------------------------------------------
#- post-install checks ---------------------------------------------------------
#{{{
# pfwd starts with '#!/usr/bin/env bash', so the bash that matters is the one
# on PATH, not the one running this installer
_bash_version() { #{{{
  local BIN
  BIN=$(command -v bash 2>/dev/null) || return 1
  # SC2016: the payload runs in the other bash; it must not expand here
  # shellcheck disable=SC2016
  "$BIN" -c 'printf "%s.%s\n" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"' 2>/dev/null
}
#}}}

_is_bash_ok() { #{{{
  local V MAJOR MINOR
  V=$(_bash_version) || return 1
  MAJOR=${V%%.*}
  MINOR=${V##*.}
  [[ "$MAJOR" =~ ^[0-9]+$ && "$MINOR" =~ ^[0-9]+$ ]] || return 1
  (( MAJOR > 4 )) && return 0
  (( MAJOR == 4 && MINOR >= 2 )) && return 0
  return 1
}
#}}}

# 0 = mikefarah/yq v4 / 1 = not installed / 2 = some other yq
_yq_status() { #{{{
  local OUT
  command -v yq >/dev/null 2>&1 || return 1
  OUT=$(yq --version 2>/dev/null)
  case "$OUT" in
    *mikefarah*|*'version v4.'*|*'version 4.'*) return 0 ;;
  esac
  return 2
}
#}}}

# missing dependencies are reported but never abort the installation
_check_deps() { #{{{
  local V RC

  if ! _is_bash_ok; then
    V=$(_bash_version)
    __show_warn "$(_err_old_bash "${V:-unknown}")"
  fi

  command -v ssh >/dev/null 2>&1 || __show_warn "$(_err_no_ssh)"

  _yq_status
  RC=$?
  case "$RC" in
    1) __show_warn "$(_err_no_yq)" ;;
    2) __show_warn "$(_err_wrong_yq "$(yq --version 2>/dev/null)")" ;;
  esac
  return 0
}
#}}}

_is_in_path() { #{{{
  case ":${PATH}:" in
    *":${1}:"*) return 0 ;;
  esac
  return 1
}
#}}}

_check_path() { #{{{
  local DIR=$1
  _is_in_path "$DIR" || __show_warn "$(_err_not_in_path "$DIR")"
  return 0
}
#}}}
#}}}

#-------------------------------------------------------------------------------
#- main ------------------------------------------------------------------------
#{{{
main() { #{{{
  local TMP VERSION URL RC

  __setup_color

  _detect_downloader || __error_end "$(_err_no_downloader)"

  _INSTALL_DIR=$(_detect_install_dir)

  _REF=$(_resolve_ref) || __error_end "$(_err_no_release)"

  _TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pfwd-install.XXXXXX") \
    || __error_end 'failed to create a temporary directory'
  trap '__cleanup' EXIT

  TMP="${_TMP_DIR}/${_BIN}"
  URL="${_RAW_BASE}/${_REF}/${_BIN}"
  __show_info "Downloading ${_BIN} ${_REF} ..."
  _fetch_file "$URL" "$TMP" || __error_end "$(_err_download_failed "$URL" "$_REF")"

  _verify "$TMP"
  RC=$?
  (( RC != 0 )) && __error_end "$(_err_verify_failed "$RC")"

  VERSION=$(_read_version "$TMP")

  _install_bin "$TMP" "$_INSTALL_DIR" || __error_end "$(_err_install_failed "$_INSTALL_DIR")"

  __show_ok "${_BIN} ${VERSION} installed to ${_INSTALL_DIR}/${_BIN}"

  _check_deps
  _check_path "$_INSTALL_DIR"

  printf "\nRun '%s config --init' to create a config template.\n" "$_BIN"
  return 0
}
#}}}

# Load the function definitions only, for bats (see test/test_install.bats).
[[ -n "$PFWD_INSTALL_SOURCE_ONLY" ]] && return 0

# Calling main on the very last line keeps a truncated download from executing
# half of this script.
main "$@"
#}}}

# vim: ts=2 sw=2 sts=2 et nu foldmethod=marker
