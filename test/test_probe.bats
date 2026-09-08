#!/usr/bin/env bats

load helper

setup() {
  setup_pfwd
  setup_run_dir
  load_config "${FIXTURES}/basic.yaml"
  command -v python3 >/dev/null 2>&1 || skip 'python3 is required for the probe tests'
  SERVER_PID=
}

teardown() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
  return 0
}

@test "probe: このバッシュでは /dev/tcp が使える" {
  _probe_detect
  [ "$_PROBE_BACKEND" = 'devtcp' ]
}

@test "probe: _probe_tcp が待ち受け中のポートに接続できる" {
  local PORT
  PORT=$(free_port)
  SERVER_PID=$(start_probe_server "$PORT" hold)
  run _probe_tcp 127.0.0.1 "$PORT"
  [ "$status" -eq 0 ]
}

@test "probe: _probe_tcp は未使用ポートで 1 を返す" {
  local PORT
  PORT=$(free_port)
  run _probe_tcp 127.0.0.1 "$PORT"
  [ "$status" -eq 1 ]
}

@test "probe: _is_port_free は使用中で 1、未使用で 0 を返す" {
  local PORT
  PORT=$(free_port)
  run _is_port_free 127.0.0.1 "$PORT"
  [ "$status" -eq 0 ]
  SERVER_PID=$(start_probe_server "$PORT" hold)
  run _is_port_free 127.0.0.1 "$PORT"
  [ "$status" -eq 1 ]
}

@test "probe: _probe_forward は接続を保持するサーバに 0 を返す" {
  local PORT
  PORT=$(free_port)
  SERVER_PID=$(start_probe_server "$PORT" hold)
  run _probe_forward 127.0.0.1 "$PORT"
  [ "$status" -eq 0 ]
}

@test "probe: _probe_forward はデータを返すサーバに 0 を返す" {
  local PORT
  PORT=$(free_port)
  SERVER_PID=$(start_probe_server "$PORT" data)
  run _probe_forward 127.0.0.1 "$PORT"
  [ "$status" -eq 0 ]
}

@test "probe: _probe_forward は即切断するサーバに 1 を返す" {
  local PORT
  PORT=$(free_port)
  SERVER_PID=$(start_probe_server "$PORT" close)
  run _probe_forward 127.0.0.1 "$PORT"
  [ "$status" -eq 1 ]
}

@test "probe: _probe_forward は待ち受けが無ければ 2 を返す" {
  local PORT
  PORT=$(free_port)
  run _probe_forward 127.0.0.1 "$PORT"
  [ "$status" -eq 2 ]
}

@test "health: process モードはプロセス生存のみを見る" {
  _ssh_is_alive() { return 0; }
  _CFG[db-prod.check_mode]=process
  _CFG[db-prod.local_port]=$(free_port)
  run _health_check db-prod
  [ "$status" -eq 0 ]
  _ssh_is_alive() { return 1; }
  run _health_check db-prod
  [ "$status" -eq 1 ]
}

@test "health: tcp モードはローカルポートの待ち受けを見る" {
  local PORT
  PORT=$(free_port)
  _ssh_is_alive() { return 0; }
  _CFG[db-prod.check_mode]=tcp
  _CFG[db-prod.local_port]=$PORT
  run _health_check db-prod
  [ "$status" -eq 1 ]
  SERVER_PID=$(start_probe_server "$PORT" hold)
  run _health_check db-prod
  [ "$status" -eq 0 ]
}

@test "health: remote モードは即切断を異常と判定する" {
  local PORT
  PORT=$(free_port)
  _ssh_is_alive() { return 0; }
  _CFG[db-prod.check_mode]=remote
  _CFG[db-prod.local_port]=$PORT
  SERVER_PID=$(start_probe_server "$PORT" close)
  run _health_check db-prod
  [ "$status" -eq 1 ]
}

@test "health: remote モードは接続維持を正常と判定する" {
  local PORT
  PORT=$(free_port)
  _ssh_is_alive() { return 0; }
  _CFG[db-prod.check_mode]=remote
  _CFG[db-prod.local_port]=$PORT
  SERVER_PID=$(start_probe_server "$PORT" hold)
  run _health_check db-prod
  [ "$status" -eq 0 ]
}
