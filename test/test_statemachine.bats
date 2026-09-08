#!/usr/bin/env bats

load helper

# ssh / プローブをスタブに差し替える
stub_ssh() {
  STARTED=0
  STOPPED=0
  ALIVE=0
  HEALTHY=0
  PORT_FREE=0
  TCP_OK=0
  SSH_ERR=''
  _ssh_start() {
    _state_set "$1" pid 4242
    _state_set "$1" conn_sig "$(_conn_sig "$1")"
    _state_set "$1" last_error ''
    _state_transit "$1" connecting
    STARTED=$(( STARTED + 1 ))
    return 0
  }
  _ssh_stop() {
    _state_set "$1" pid 0
    STOPPED=$(( STOPPED + 1 ))
    return 0
  }
  _ssh_is_alive()   { return "$ALIVE"; }
  _health_check()   { return "$HEALTHY"; }
  _is_port_free()   { return "$PORT_FREE"; }
  _probe_tcp()      { return "$TCP_OK"; }
  _ssh_take_error() { printf '%s\n' "$SSH_ERR"; }
}

setup() {
  setup_pfwd
  setup_run_dir
  load_config "${FIXTURES}/basic.yaml"
  stub_ssh
  _LOG_FILE="${_RUN_DIR}/pfwd.log"
  _state_load_all
  NOW=$(_now)
}

@test "sm: connecting からポートが開けば connected になる" {
  _state_transit db-prod connecting
  TCP_OK=0
  _daemon_tick_entry db-prod "$NOW"
  [ "${_ST[db-prod.status]}" = 'connected' ]
  [ "${_ST[db-prod.connected_since]}" = "$NOW" ]
  grep -q 'connection established' "$_LOG_FILE"
}

@test "sm: connecting のまま connect_timeout+2 を超えたら retrying になる" {
  _state_transit db-prod connecting
  TCP_OK=1
  _state_set db-prod since $(( NOW - 20 ))
  _daemon_tick_entry db-prod "$NOW"
  [ "${_ST[db-prod.status]}" = 'retrying' ]
  [ "$STOPPED" -eq 1 ]
  [ "${_ST[db-prod.backoff]}" = '5' ]
}

@test "sm: connecting 中に ssh が死んだら retrying になる" {
  _state_transit db-prod connecting
  ALIVE=1
  SSH_ERR='ssh: connect to host bastion.example.com port 22: Connection timed out'
  _daemon_tick_entry db-prod "$NOW"
  [ "${_ST[db-prod.status]}" = 'retrying' ]
  [ "${_ST[db-prod.retry_count]}" = '1' ]
  [ "${_ST[db-prod.next_retry_at]}" = "$(( NOW + 5 ))" ]
  [[ "${_ST[db-prod.last_error]}" == *'Connection timed out'* ]]
}

@test "sm: 復帰しえないエラーでは即 failed になる" {
  _state_transit db-prod connecting
  ALIVE=1
  SSH_ERR='Host key verification failed.'
  _daemon_tick_entry db-prod "$NOW"
  [ "${_ST[db-prod.status]}" = 'failed' ]
  grep -q 'ssh-keyscan -H bastion.example.com' "$_LOG_FILE"
}

@test "sm: connected で死活監視が失敗したら停止して retrying になる" {
  _state_transit db-prod connected
  _state_set db-prod next_check_at "$NOW"
  HEALTHY=1
  _daemon_tick_entry db-prod "$NOW"
  [ "$STOPPED" -eq 1 ]
  [ "${_ST[db-prod.status]}" = 'retrying' ]
  grep -q 'health check failed' "$_LOG_FILE"
  grep -q 'reconnecting in 5s (attempt 1)' "$_LOG_FILE"
}

@test "sm: connected で監視時刻前なら何もしない" {
  _state_transit db-prod connected
  _state_set db-prod next_check_at $(( NOW + 30 ))
  HEALTHY=1
  _daemon_tick_entry db-prod "$NOW"
  [ "${_ST[db-prod.status]}" = 'connected' ]
  [ "$STOPPED" -eq 0 ]
}

@test "sm: バックオフは 5→10→20→…→300 で頭打ちになる" {
  local EXPECT=(5 10 20 40 80 160 300 300 300)
  local I T=$NOW
  _state_transit db-prod connecting
  ALIVE=1
  SSH_ERR='ssh: connect to host h port 22: Connection refused'
  for (( I = 0; I < ${#EXPECT[@]}; I++ )); do
    _state_transit db-prod connecting
    _daemon_tick_entry db-prod "$T"
    [ "${_ST[db-prod.backoff]}" = "${EXPECT[$I]}" ]
    [ "${_ST[db-prod.retry_count]}" = "$(( I + 1 ))" ]
    T=$(( T + EXPECT[I] ))
  done
}

@test "sm: 60 秒以上つながっていたらバックオフがリセットされる" {
  _state_transit db-prod connected
  _state_set db-prod retry_count 4
  _state_set db-prod backoff 80
  _state_set db-prod connected_since $(( NOW - 61 ))
  _state_set db-prod next_check_at "$NOW"
  HEALTHY=0
  _daemon_tick_entry db-prod "$NOW"
  [ "${_ST[db-prod.retry_count]}" = '0' ]
  [ "${_ST[db-prod.backoff]}" = '5' ]
  [ "${_ST[db-prod.status]}" = 'connected' ]
}

@test "sm: 60 秒未満ならバックオフは維持される" {
  _state_transit db-prod connected
  _state_set db-prod retry_count 4
  _state_set db-prod backoff 80
  _state_set db-prod connected_since $(( NOW - 30 ))
  _state_set db-prod next_check_at "$NOW"
  HEALTHY=0
  _daemon_tick_entry db-prod "$NOW"
  [ "${_ST[db-prod.retry_count]}" = '4' ]
  [ "${_ST[db-prod.backoff]}" = '80' ]
}

@test "sm: retrying は待機時刻まで何もしない" {
  _state_transit db-prod retrying
  _state_set db-prod next_retry_at $(( NOW + 5 ))
  _daemon_tick_entry db-prod "$NOW"
  [ "$STARTED" -eq 0 ]
  [ "${_ST[db-prod.status]}" = 'retrying' ]
}

@test "sm: retrying は待機時刻を過ぎたら再接続する" {
  _state_transit db-prod retrying
  _state_set db-prod next_retry_at "$NOW"
  _daemon_tick_entry db-prod "$NOW"
  [ "$STARTED" -eq 1 ]
  [ "${_ST[db-prod.status]}" = 'connecting' ]
}

@test "sm: retry_limit に達したら failed になる" {
  _GLOBAL[retry_limit]=3
  _state_transit db-prod retrying
  _state_set db-prod retry_count 3
  _state_set db-prod next_retry_at "$NOW"
  _daemon_tick_entry db-prod "$NOW"
  [ "${_ST[db-prod.status]}" = 'failed' ]
  [ "$STARTED" -eq 0 ]
  [[ "${_ST[db-prod.last_error]}" == *'retry limit'* ]]
}

@test "sm: ローカルポート使用中なら再試行せず failed になる" {
  _state_transit db-prod retrying
  _state_set db-prod next_retry_at "$NOW"
  PORT_FREE=1
  _daemon_tick_entry db-prod "$NOW"
  [ "${_ST[db-prod.status]}" = 'failed' ]
  [ "$STARTED" -eq 0 ]
  [[ "${_ST[db-prod.last_error]}" == *'already in use'* ]]
}

@test "sm: stopped / disabled / failed ではデーモンは何もしない" {
  local S
  for S in stopped disabled failed; do
    _state_transit db-prod "$S"
    _daemon_tick_entry db-prod "$NOW"
    [ "${_ST[db-prod.status]}" = "$S" ]
  done
  [ "$STARTED" -eq 0 ]
  [ "$STOPPED" -eq 0 ]
}

@test "sm: 1 サイクルの死活監視数は上限で頭打ちになる" {
  local NAME
  _MAX_CHECKS_PER_TICK=2
  HEALTHY=0
  for NAME in "${_CFG_NAMES[@]}"; do
    _state_transit "$NAME" connected
    _state_set "$NAME" next_check_at "$NOW"
  done
  _CHECKS_THIS_TICK=0
  for NAME in "${_CFG_NAMES[@]}"; do
    _daemon_tick_entry "$NAME" "$NOW"
  done
  [ "$_CHECKS_THIS_TICK" -eq 2 ]
  [ "${_ST[metrics.next_check_at]}" = "$NOW" ]
}

@test "reconcile: desired=up かつ stopped なら起動する" {
  _state_transit db-prod stopped
  _desired_set db-prod up
  _daemon_reconcile
  [ "${_ST[db-prod.status]}" = 'connecting' ]
}

@test "reconcile: desired=up かつ connected なら何もしない (冪等)" {
  _state_transit db-prod connected
  _desired_set db-prod up
  _daemon_reconcile
  [ "$STARTED" -eq 0 ]
  [ "${_ST[db-prod.status]}" = 'connected' ]
}

@test "reconcile: desired=down なら停止する" {
  _state_transit db-prod connected
  _desired_set db-prod down
  _daemon_reconcile
  [ "$STOPPED" -eq 1 ]
  [ "${_ST[db-prod.status]}" = 'stopped' ]
}

@test "reconcile: desired=down かつ stopped なら何もしない (冪等)" {
  _state_transit db-prod stopped
  _desired_set db-prod down
  _daemon_reconcile
  [ "$STOPPED" -eq 0 ]
  [ "${_ST[db-prod.status]}" = 'stopped' ]
}

@test "reconcile: failed からもバックオフをリセットして起動する" {
  _state_transit db-prod failed
  _state_set db-prod retry_count 9
  _state_set db-prod backoff 300
  _desired_set db-prod up
  _daemon_reconcile
  [ "${_ST[db-prod.status]}" = 'connecting' ]
  [ "${_ST[db-prod.retry_count]}" = '0' ]
  [ "${_ST[db-prod.backoff]}" = '5' ]
}

@test "reconcile: enabled=false は desired が無ければ disabled のまま" {
  _CFG[db-prod.enabled]=false
  _state_transit db-prod disabled
  _daemon_reconcile
  [ "${_ST[db-prod.status]}" = 'disabled' ]
  [ "$STARTED" -eq 0 ]
}

@test "reconcile: enabled=false でも desired=up なら起動する" {
  _CFG[db-prod.enabled]=false
  _state_transit db-prod disabled
  _desired_set db-prod up
  _daemon_reconcile
  [ "${_ST[db-prod.status]}" = 'connecting' ]
}

@test "reconcile: 起動前にローカルポートが使用中なら failed になる" {
  _state_transit db-prod stopped
  _desired_set db-prod up
  PORT_FREE=1
  _daemon_reconcile
  [ "${_ST[db-prod.status]}" = 'failed' ]
}

@test "reconcile: 無効エントリには手を出さない" {
  _CFG_INVALID[db-prod]='missing required key'
  _state_transit db-prod failed
  _desired_set db-prod up
  _daemon_reconcile
  [ "${_ST[db-prod.status]}" = 'failed' ]
  [ "$STARTED" -eq 0 ]
}

@test "lock: 二重取得は失敗し、stale ロックは回収される" {
  run _daemon_lock_acquire
  [ "$status" -eq 0 ]
  [ -d "${_RUN_DIR}/daemon.lock" ]
  # 生きているプロセスの PID が入っていれば取得できない
  printf '%s\n' "$$" > "${_RUN_DIR}/daemon.lock/pid"
  run _daemon_lock_acquire
  [ "$status" -eq 1 ]
  # 死んだ PID なら回収して取得できる
  printf '999999\n' > "${_RUN_DIR}/daemon.lock/pid"
  run _daemon_lock_acquire
  [ "$status" -eq 0 ]
}

# --- reload ------------------------------------------------------------------

write_reload_config() { # write_reload_config <version>
  local V=$1
  case "$V" in
    v1)
      cat > "$RELOAD_CFG" <<'YAML'
entries:
  keep:
    description: original
    host: bastion.example.com
    local_port: 15001
    remote_port: 5432
  changing:
    host: bastion.example.com
    local_port: 15002
    remote_port: 5432
  going-away:
    host: bastion.example.com
    local_port: 15003
    remote_port: 5432
YAML
      ;;
    v2)
      cat > "$RELOAD_CFG" <<'YAML'
entries:
  keep:
    description: updated description
    host: bastion.example.com
    local_port: 15001
    remote_port: 5432
  changing:
    host: bastion.example.com
    local_port: 15099
    remote_port: 5432
  added:
    host: bastion.example.com
    local_port: 15004
    remote_port: 5432
YAML
      ;;
    disabled)
      cat > "$RELOAD_CFG" <<'YAML'
entries:
  keep:
    description: original
    host: bastion.example.com
    local_port: 15001
    remote_port: 5432
    enabled: false
YAML
      ;;
    broken)
      printf 'entries:\n  keep: [\n' > "$RELOAD_CFG"
      ;;
  esac
}

setup_reload() {
  RELOAD_CFG="${BATS_TEST_TMPDIR}/reload.yaml"
  write_reload_config v1
  _config_reset
  _OPT_CONFIG=$RELOAD_CFG
  _config_setup
  _state_load_all
  local NAME
  for NAME in "${_CFG_NAMES[@]}"; do
    _state_transit "$NAME" connected
    _state_set "$NAME" pid 4242
    _state_set "$NAME" conn_sig "$(_conn_sig "$NAME")"
  done
  STARTED=0
  STOPPED=0
}

@test "reload: 追加されたエントリを起動する" {
  setup_reload
  write_reload_config v2
  _daemon_reload
  [ -n "${_CFG[added.host]}" ]
  [ "${_ST[added.status]}" = 'connecting' ]
  grep -q 'config reloaded (added=1' "$_LOG_FILE"
}

@test "reload: 削除されたエントリを停止して状態も消す" {
  setup_reload
  write_reload_config v2
  _daemon_reload
  [ -z "${_ST[going-away.status]}" ]
  [ ! -e "${_RUN_DIR}/state/going-away.state" ]
  grep -q 'removed=1' "$_LOG_FILE"
}

@test "reload: 接続パラメータが変わったエントリだけ再起動する" {
  setup_reload
  write_reload_config v2
  _daemon_reload
  [ "${_ST[changing.status]}" = 'connecting' ]
  grep -q 'restarted=1' "$_LOG_FILE"
}

@test "reload: description のみの変更ではセッションを維持する" {
  setup_reload
  write_reload_config v2
  _daemon_reload
  [ "${_ST[keep.status]}" = 'connected' ]
  [ "${_CFG[keep.description]}" = 'updated description' ]
}

@test "reload: enabled=false になったエントリを停止して disabled にする" {
  setup_reload
  _desired_set keep up
  write_reload_config disabled
  _daemon_reload
  [ "${_ST[keep.status]}" = 'disabled' ]
  [ ! -e "${_RUN_DIR}/state/keep.desired" ]
}

@test "reload: 設定が壊れていたら旧設定を維持して継続する" {
  setup_reload
  write_reload_config broken
  run _daemon_reload
  [ "$status" -eq 1 ]
  _daemon_reload
  [ "${#_CFG_NAMES[@]}" -eq 3 ]
  [ "${_CFG[keep.description]}" = 'original' ]
  grep -q 'config reload failed; keeping the previous configuration' "$_LOG_FILE"
}
