#!/usr/bin/env bats

load helper

setup() {
  setup_pfwd
  setup_run_dir
  load_config "${FIXTURES}/basic.yaml"
}

@test "state: ファイルが無ければ既定値で初期化される" {
  run -1 _state_load db-prod
  _state_load db-prod
  [ "${_ST[db-prod.status]}" = 'stopped' ]
  [ "${_ST[db-prod.pid]}" = '0' ]
  [ "${_ST[db-prod.retry_count]}" = '0' ]
}

@test "state: 書き込みと読み出しが往復する" {
  _state_load db-prod
  _state_set db-prod status connected
  _state_set db-prod pid 12345
  _state_set db-prod ctl "${_RUN_DIR}/ctl/db-prod.sock"
  _state_set db-prod last_error 'ssh: connect failed'
  _state_flush db-prod
  _ST=()
  _state_load db-prod
  [ "${_ST[db-prod.status]}" = 'connected' ]
  [ "${_ST[db-prod.pid]}" = '12345' ]
  [ "${_ST[db-prod.ctl]}" = "${_RUN_DIR}/ctl/db-prod.sock" ]
  [ "${_ST[db-prod.last_error]}" = 'ssh: connect failed' ]
}

@test "state: アトミックに書き込まれ一時ファイルが残らない" {
  _state_load db-prod
  _state_set db-prod status connecting
  _state_flush db-prod
  [ -f "${_RUN_DIR}/state/db-prod.state" ]
  [ ! -e "${_RUN_DIR}/err/db-prod.state.tmp" ]
}

@test "state: flush 後に dirty フラグが落ちる" {
  _state_load db-prod
  _state_set db-prod status connecting
  [ "${_ST_DIRTY[db-prod]}" = '1' ]
  _state_flush_dirty
  [ "${#_ST_DIRTY[@]}" -eq 0 ]
}

@test "state: state ファイルは source されない" {
  _state_load db-prod
  _state_flush db-prod
  printf 'status=connected\nrm=touch %s/pwned\n' "$_RUN_DIR" >> "${_RUN_DIR}/state/db-prod.state"
  _state_load db-prod
  [ "${_ST[db-prod.status]}" = 'connected' ]
  [ ! -e "${_RUN_DIR}/pwned" ]
}

@test "state: _state_transit はログを 1 行出す" {
  _LOG_FILE="${_RUN_DIR}/pfwd.log"
  _state_load db-prod
  _state_transit db-prod connecting
  [ "$(wc -l < "$_LOG_FILE")" -eq 1 ]
  grep -q '\[INFO \] \[db-prod\] state: stopped -> connecting' "$_LOG_FILE"
  [ "${_ST[db-prod.status]}" = 'connecting' ]
}

@test "state: 同じ状態への遷移ではログを出さない" {
  _LOG_FILE="${_RUN_DIR}/pfwd.log"
  : > "$_LOG_FILE"
  _state_load db-prod
  _state_transit db-prod stopped
  [ ! -s "$_LOG_FILE" ]
}

@test "state: 理由付きの遷移はログに理由が入る" {
  _LOG_FILE="${_RUN_DIR}/pfwd.log"
  _state_load db-prod
  _state_transit db-prod failed 'retry limit reached'
  grep -q 'state: stopped -> failed (retry limit reached)' "$_LOG_FILE"
}

@test "state: _state_remove がファイルと内部状態を消す" {
  _state_load db-prod
  _state_flush db-prod
  _desired_set db-prod up
  touch "${_RUN_DIR}/err/db-prod.err"
  _state_remove db-prod
  [ ! -e "${_RUN_DIR}/state/db-prod.state" ]
  [ ! -e "${_RUN_DIR}/state/db-prod.desired" ]
  [ ! -e "${_RUN_DIR}/err/db-prod.err" ]
  [ -z "${_ST[db-prod.status]}" ]
}

@test "desired: ファイルが無ければ enabled に従う" {
  [ "$(_desired_get db-prod)" = 'up' ]
  _CFG[db-prod.enabled]=false
  [ "$(_desired_get db-prod)" = 'down' ]
}

@test "desired: 書き込んだ値が読み出せる" {
  _desired_set db-prod down
  [ "$(_desired_get db-prod)" = 'down' ]
  _desired_set db-prod up
  [ "$(_desired_get db-prod)" = 'up' ]
  [ ! -e "${_RUN_DIR}/err/db-prod.desired.tmp" ]
}

@test "desired: 不正な内容は enabled の既定にフォールバックする" {
  printf 'garbage\n' > "${_RUN_DIR}/state/db-prod.desired"
  [ "$(_desired_get db-prod)" = 'up' ]
}

@test "desired: _desired_remove でファイルが消える" {
  _desired_set db-prod down
  _desired_remove db-prod
  [ ! -e "${_RUN_DIR}/state/db-prod.desired" ]
  [ "$(_desired_get db-prod)" = 'up' ]
}

@test "log: ログ形式が SPECS 6.5 に従う" {
  _LOG_FILE="${_RUN_DIR}/pfwd.log"
  _log_info db-prod 'connection established (pid=48213)'
  _log_warn metrics 'health check failed'
  _log_error - 'daemon error'
  grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4} \[INFO \] \[db-prod\] connection established \(pid=48213\)$' "$_LOG_FILE"
  grep -qE '\[WARN \] \[metrics\] health check failed$' "$_LOG_FILE"
  grep -qE '\[ERROR\] daemon error$' "$_LOG_FILE"
}

@test "log: 制御文字はログに書く前に除去される" {
  _LOG_FILE="${_RUN_DIR}/pfwd.log"
  _log_info db-prod "$(printf 'line1\nline2\tend')"
  [ "$(wc -l < "$_LOG_FILE")" -eq 1 ]
  grep -q 'line1 line2 end' "$_LOG_FILE"
}

@test "log: log_file 未指定なら標準出力に出る" {
  _LOG_FILE=
  run _log_info db-prod 'to stdout'
  [ "$status" -eq 0 ]
  [[ "$output" == *'[INFO ] [db-prod] to stdout' ]]
}

@test "log: -v 指定時のみ _debug が標準エラーに出る" {
  _VERBOSE=0
  run --separate-stderr _debug 'hidden'
  [ -z "$stderr" ]
  _VERBOSE=1
  run --separate-stderr _debug 'shown'
  [[ "$stderr" == *'[DEBUG] shown' ]]
}
