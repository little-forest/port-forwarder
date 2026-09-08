#!/usr/bin/env bats
#
# 実際に localhost へ ssh してフォワードを張る結合テスト。
# 破壊的かつ環境依存のため、PFWD_IT=1 のときだけ実行する。
#
#   PFWD_IT=1 bats test/test_integration.bats
#
# 前提:
#   - localhost に sshd が動作し、公開鍵認証で 'ssh localhost true' が通ること
#   - python3 が使えること

load helper

IT_TIMEOUT=40

setup() {
  [[ "$PFWD_IT" == '1' ]] || skip 'PFWD_IT=1 のときのみ実行する'
  command -v python3 >/dev/null 2>&1 || skip 'python3 が必要'
  ssh -T -o BatchMode=yes -o ConnectTimeout=5 localhost true >/dev/null 2>&1 \
    || skip 'localhost へ公開鍵認証で ssh できないためスキップ'

  setup_pfwd
  IT_RUNTIME=$(mktemp -d "${BATS_TEST_TMPDIR}/itrun.XXXXXX")
  IT_LOG="${BATS_TEST_TMPDIR}/pfwd.log"
  REMOTE_PORT=$(free_port)
  LOCAL_PORT=$(free_port)
  SERVER_PID=$(start_probe_server "$REMOTE_PORT" data)
  IT_CFG="${BATS_TEST_TMPDIR}/it.yaml"
  cat > "$IT_CFG" <<YAML
global:
  check_interval: 5
  connect_timeout: 10
  retry_initial: 2
  retry_max: 10
  log_file: ${IT_LOG}
entries:
  it-tunnel:
    description: integration test tunnel
    host: localhost
    local_port: ${LOCAL_PORT}
    remote_host: 127.0.0.1
    remote_port: ${REMOTE_PORT}
    check_mode: remote
YAML
}

teardown() {
  [[ -n "$IT_RUNTIME" ]] && XDG_RUNTIME_DIR=$IT_RUNTIME "$PFWD" --config "$IT_CFG" down >/dev/null 2>&1
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
  return 0
}

pfwd_it() {
  XDG_RUNTIME_DIR=$IT_RUNTIME "$PFWD" --config "$IT_CFG" --no-color "$@"
}

# エントリが指定の状態になるまで待つ
wait_status() {
  local WANT=$1 I OUT
  for (( I = 0; I < IT_TIMEOUT * 2; I++ )); do
    OUT=$(pfwd_it status it-tunnel 2>/dev/null)
    [[ "$OUT" == *" ${WANT} "* ]] && return 0
    sleep 0.5
  done
  printf 'timed out waiting for status=%s\n%s\n' "$WANT" "$OUT" >&2
  return 1
}

@test "it: up から status / データ転送 / stop / start / 自動再接続 / down まで通る" {
  run pfwd_it test it-tunnel
  [ "$status" -eq 0 ]

  run pfwd_it up
  [ "$status" -eq 0 ]

  wait_status connected

  # 転送先まで実際に到達すること (data サーバは 1 バイト送ってくる)
  run _probe_forward 127.0.0.1 "$LOCAL_PORT"
  [ "$status" -eq 0 ]

  run pfwd_it status --exit-code
  [ "$status" -eq 0 ]

  # 停止するとローカルポートが閉じること
  run pfwd_it stop it-tunnel
  [ "$status" -eq 0 ]
  wait_status stopped
  run _probe_tcp 127.0.0.1 "$LOCAL_PORT"
  [ "$status" -eq 1 ]

  # 再開できること (冪等: 2 回目は SKIP)
  run pfwd_it start it-tunnel
  [ "$status" -eq 0 ]
  wait_status connected
  run pfwd_it start it-tunnel
  [ "$status" -eq 0 ]
  [[ "$output" == *'[ SKIP ]'* ]]

  # 外部から ssh を kill しても再接続すること
  local SSH_PID
  SSH_PID=$(grep '^pid=' "${IT_RUNTIME}/port-forwarder/state/it-tunnel.state" | cut -d= -f2)
  [ -n "$SSH_PID" ]
  kill -KILL "$SSH_PID"
  wait_status retrying
  wait_status connected
  grep -q 'reconnecting in' "$IT_LOG"

  # 停止すると ssh も残らないこと
  run pfwd_it down
  [ "$status" -eq 0 ]
  run pfwd_it status
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == 'daemon: not running' ]]
  ! kill -0 "$SSH_PID" 2>/dev/null
  [ ! -e "${IT_RUNTIME}/port-forwarder/daemon.pid" ]
}

@test "it: reload で接続パラメータの変更が反映される" {
  run pfwd_it up
  [ "$status" -eq 0 ]
  wait_status connected

  local NEW_PORT
  NEW_PORT=$(free_port)
  sed -i.bak "s/local_port: ${LOCAL_PORT}/local_port: ${NEW_PORT}/" "$IT_CFG"

  run pfwd_it reload
  [ "$status" -eq 0 ]
  wait_status connected
  run _probe_tcp 127.0.0.1 "$NEW_PORT"
  [ "$status" -eq 0 ]
  run _probe_tcp 127.0.0.1 "$LOCAL_PORT"
  [ "$status" -eq 1 ]
}
