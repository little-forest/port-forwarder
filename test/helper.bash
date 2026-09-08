#!/usr/bin/env bash
# bats 共通セットアップ
bats_require_minimum_version 1.5.0

PFWD_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export PFWD_ROOT
FIXTURES="${PFWD_ROOT}/test/fixtures"
export FIXTURES
PFWD="${PFWD_ROOT}/pfwd"
export PFWD

# pfwd を関数定義のみ読み込む。
# 関数内で source すると declare -A が局所変数になってしまうため、
# 必ずファイルスコープ (= テストプロセスのトップレベル) で読み込む。
export PFWD_SOURCE_ONLY=1
# shellcheck source=/dev/null
source "$PFWD"
# pfwd が張る trap EXIT は bats の結果報告と干渉するため外す
trap - EXIT

# グローバル状態を初期化する。各テストの setup から呼ぶ
setup_pfwd() {
  # pfwd は set -e を使わない前提で書かれている (DESIGN 2.2) ため、
  # bats が有効にする errexit を無効化してから関数を呼ぶ
  set +e
  _CFG=()
  _CFG_OPTS=()
  _GLOBAL=()
  _CFG_INVALID=()
  _CFG_SOURCE=()
  _ST=()
  _ST_DIRTY=()
  _CFG_NAMES=()
  _CONFIG_FILES=()
  _CONFIG_FILE=
  _OPT_CONFIG=
  _LOG_FILE=
  _VERBOSE=0
  _QUIET=
  _NO_TTY=yes
  __SILENT=yes
}

# 一時的な実行時ディレクトリを用意する
setup_run_dir() {
  _RUN_DIR=$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/pfwd-run.XXXXXX")
  mkdir -p "${_RUN_DIR}/state" "${_RUN_DIR}/ctl" "${_RUN_DIR}/err"
}

# 設定ファイルを読み込む (main を通さずに)
load_config() {
  local F
  _OPT_CONFIG=$1
  _config_find
  _config_file_list
  for F in "${_CONFIG_FILES[@]}"; do
    _config_parse_file "$F"
  done
  _config_apply_defaults
  _config_validate
  return 0
}
