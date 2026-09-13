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
  # pfwd は $0 と $$ から __TMP_BASE を決めるため、source した bats の
  # テストプロセスでは /dev/shm や Ramdisk に tmp.bats-exec-test.<pid> を作る。
  # helper が trap EXIT を外している以上 __script_end_clean_tmp は走らないので、
  # bats が後始末するテスト用一時ディレクトリ配下へ寄せる
  __TMP_BASE="${BATS_TEST_TMPDIR}/tmp.pfwd"
  # _ctl_path が ControlPath を退避させる先 (${TMPDIR}/pfwd-<uid>) も
  # 実 TMPDIR に残り続けるため、同じくテスト用一時ディレクトリへ向ける
  export TMPDIR="$BATS_TEST_TMPDIR"
}

# 一時的な実行時ディレクトリを用意する
setup_run_dir() {
  # ControlPath の上限は 100 バイト (_CTL_PATH_MAX)。macOS の BATS_TEST_TMPDIR は
  # /var/folders/... 配下で 70 文字を超えるため、ここで長い名前を付けると
  # ${_RUN_DIR}/ctl/<name>.sock が上限を超え、_ctl_path が TMPDIR 退避に倒れる。
  # 退避経路を検証するテスト以外では起こしたくないので名前を詰めておく
  _RUN_DIR=$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/r.XXXX")
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

# 空きポートを 1 つ返す
free_port() {
  local P I
  for (( I = 0; I < 100; I++ )); do
    P=$(( 20000 + RANDOM % 10000 ))
    if ! { exec 3<>"/dev/tcp/127.0.0.1/${P}"; } 2>/dev/null; then
      printf '%s\n' "$P"
      return 0
    fi
  done
  return 1
}

# プローブ検証用の TCP サーバを起動する
#   start_probe_server <port> <hold|close|data>   -> PID を返す
start_probe_server() {
  local PORT=$1 MODE=$2 PID I
  python3 -c '
import socket, sys
port, mode = int(sys.argv[1]), sys.argv[2]
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(8)
held = []
while True:
    c, _ = s.accept()
    if mode == "close":
        c.close()
    elif mode == "data":
        c.sendall(b"x")
        held.append(c)
    else:
        held.append(c)
' "$PORT" "$MODE" >/dev/null 2>&1 &
  PID=$!
  for (( I = 0; I < 50; I++ )); do
    if { exec 3<>"/dev/tcp/127.0.0.1/${PORT}"; } 2>/dev/null; then
      printf '%s\n' "$PID"
      return 0
    fi
    sleep 0.1
  done
  kill "$PID" 2>/dev/null
  return 1
}
