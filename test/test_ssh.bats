#!/usr/bin/env bats

load helper

setup() {
  setup_pfwd
  setup_run_dir
  load_config "${FIXTURES}/basic.yaml"
}

@test "ssh: _ctl_path は実行時ディレクトリ配下を返す" {
  run _ctl_path db-prod
  [ "$status" -eq 0 ]
  [ "$output" = "${_RUN_DIR}/ctl/db-prod.sock" ]
}

@test "ssh: パスが長すぎる場合は TMPDIR 配下に退避する" {
  local DEEP="${BATS_TEST_TMPDIR}/$(printf 'd%.0s' {1..90})"
  mkdir -p "${DEEP}/ctl"
  _RUN_DIR=$DEEP
  run _ctl_path db-prod
  [ "$status" -eq 0 ]
  [ "${#output}" -le 100 ]
  [[ "$output" == "${TMPDIR:-/tmp}/pfwd-${EUID}/"*'.sock' ]]
}

@test "ssh: conn_sig は接続パラメータの変更で変わる" {
  local SIG1 SIG2
  SIG1=$(_conn_sig db-prod)
  _CFG[db-prod.description]='changed description'
  SIG2=$(_conn_sig db-prod)
  [ "$SIG1" = "$SIG2" ]
  _CFG[db-prod.host]='other.example.com'
  SIG2=$(_conn_sig db-prod)
  [ "$SIG1" != "$SIG2" ]
}

@test "ssh: conn_sig は check_mode の変更では変わらない" {
  local SIG1 SIG2
  SIG1=$(_conn_sig db-prod)
  _CFG[db-prod.check_mode]=tcp
  _CFG[db-prod.check_interval]=99
  _CFG[db-prod.enabled]=false
  SIG2=$(_conn_sig db-prod)
  [ "$SIG1" = "$SIG2" ]
}

@test "ssh: 起動引数に必要なオプションが並ぶ" {
  _ssh_build_args db-prod "${_RUN_DIR}/ctl/db-prod.sock"
  local ARGS=" ${_SSH_ARGS[*]} "
  [[ "$ARGS" == *' -N -T -M -S '* ]]
  [[ "$ARGS" == *' -o ExitOnForwardFailure=yes '* ]]
  [[ "$ARGS" == *' -o BatchMode=yes '* ]]
  [[ "$ARGS" == *' -o StrictHostKeyChecking=yes '* ]]
  [[ "$ARGS" == *' -o ConnectTimeout=10 '* ]]
  [[ "$ARGS" == *' -o ServerAliveInterval=15 '* ]]
  [[ "$ARGS" == *' -L 127.0.0.1:15432:db.internal:5432 '* ]]
  [[ "$ARGS" == *' -l komori '* ]]
  [ "${_SSH_ARGS[${#_SSH_ARGS[@]}-1]}" = 'bastion.example.com' ]
}

@test "ssh: identity 指定時は IdentitiesOnly が付く" {
  local KEY="${BATS_TEST_TMPDIR}/id_test"
  touch "$KEY"; chmod 600 "$KEY"
  _CFG[db-prod.identity]=$KEY
  _ssh_build_args db-prod "${_RUN_DIR}/ctl/db-prod.sock"
  local ARGS=" ${_SSH_ARGS[*]} "
  [[ "$ARGS" == *" -o IdentitiesOnly=yes -i ${KEY} "* ]]
}

@test "ssh: user が空なら -l を渡さない" {
  _CFG[db-prod.user]=
  _ssh_build_args db-prod "${_RUN_DIR}/ctl/db-prod.sock"
  local ARGS=" ${_SSH_ARGS[*]} "
  [[ "$ARGS" != *' -l '* ]]
}

@test "ssh: ユーザー指定の ssh_options は既定の後に並ぶ" {
  _ssh_build_args metrics "${_RUN_DIR}/ctl/metrics.sock"
  local I DEFAULT_IDX=-1 USER_IDX=-1
  for (( I = 0; I < ${#_SSH_ARGS[@]}; I++ )); do
    [[ "${_SSH_ARGS[$I]}" == 'StrictHostKeyChecking=yes' ]] && DEFAULT_IDX=$I
    [[ "${_SSH_ARGS[$I]}" == 'Compression=yes' ]] && USER_IDX=$I
  done
  [ "$DEFAULT_IDX" -ge 0 ]
  [ "$USER_IDX" -gt "$DEFAULT_IDX" ]
}

@test "ssh: ホスト名に空白があっても引数が壊れない" {
  _CFG[db-prod.host]='host with space'
  _ssh_build_args db-prod "${_RUN_DIR}/ctl/db-prod.sock"
  [ "${_SSH_ARGS[${#_SSH_ARGS[@]}-1]}" = 'host with space' ]
}

@test "ssh: _ssh_take_error は末尾の意味のある行を返しファイルを切り詰める" {
  local F="${_RUN_DIR}/err/db-prod.err"
  printf 'Warning: Permanently added 1.2.3.4 to the list of known hosts.\nssh: connect to host bastion.example.com port 22: Connection timed out\n\n' > "$F"
  run _ssh_take_error db-prod
  [ "$status" -eq 0 ]
  [ "$output" = 'ssh: connect to host bastion.example.com port 22: Connection timed out' ]
  [ ! -s "$F" ]
}

@test "ssh: _ssh_take_error は制御文字を除去する" {
  local F="${_RUN_DIR}/err/db-prod.err"
  printf 'bad\tline\n' > "$F"
  run _ssh_take_error db-prod
  [ "$output" = 'bad line' ]
}

@test "ssh: エラー分類が SPECS の方針に従う" {
  [ "$(_ssh_classify_error 'Host key verification failed.')" = 'fatal' ]
  [ "$(_ssh_classify_error 'komori@h: Permission denied (publickey).')" = 'fatal' ]
  [ "$(_ssh_classify_error 'Enter passphrase for key /home/x/.ssh/id_rsa:')" = 'fatal' ]
  [ "$(_ssh_classify_error 'bind: Address already in use')" = 'fatal' ]
  [ "$(_ssh_classify_error 'ssh: connect to host h port 22: Connection timed out')" = 'retry' ]
  [ "$(_ssh_classify_error 'ssh: connect to host h port 22: Connection refused')" = 'retry' ]
  [ "$(_ssh_classify_error 'kex_exchange_identification: read: Broken pipe')" = 'retry' ]
}

@test "ssh: パスフレーズ鍵には ssh-agent の案内を出す" {
  run _ssh_error_hint db-prod 'Enter passphrase for key: '
  [[ "$output" == *'passphrase-protected key requires ssh-agent'* ]]
}

@test "ssh: ホスト鍵未登録には ssh-keyscan の案内を出す" {
  run _ssh_error_hint db-prod 'Host key verification failed.'
  [[ "$output" == *'ssh-keyscan -H bastion.example.com'* ]]
}

@test "ssh: _ssh_stop は生きているプロセスを終了させ pid を 0 にする" {
  sleep 30 &
  local PID=$!
  _state_load db-prod
  _state_set db-prod pid "$PID"
  _state_set db-prod ctl ''
  _ssh_stop db-prod
  [ "${_ST[db-prod.pid]}" = '0' ]
  ! kill -0 "$PID" 2>/dev/null
}

@test "ssh: _ssh_stop は既に死んでいるプロセスでも成功する" {
  _state_load db-prod
  _state_set db-prod pid 0
  run _ssh_stop db-prod
  [ "$status" -eq 0 ]
}

@test "ssh: _ssh_start が ssh を起動し connecting に遷移する" {
  _LOG_FILE="${_RUN_DIR}/pfwd.log"
  _CFG[db-prod.host]=127.0.0.1
  _CFG[db-prod.port]=1
  _CFG[db-prod.user]=
  _state_load db-prod
  _ssh_start db-prod
  [ "${_ST[db-prod.status]}" = 'connecting' ]
  [ "${_ST[db-prod.pid]}" -gt 0 ]
  [ -n "${_ST[db-prod.conn_sig]}" ]
  local I
  for (( I = 0; I < 50; I++ )); do
    kill -0 "${_ST[db-prod.pid]}" 2>/dev/null || break
    sleep 0.1
  done
  run _ssh_take_error db-prod
  [[ "$output" == *'Connection refused'* ]]
  [ "$(_ssh_classify_error "$output")" = 'retry' ]
}
