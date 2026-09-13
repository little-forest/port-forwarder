#!/usr/bin/env bats

load helper

setup() {
  setup_pfwd
  setup_run_dir
  RUNTIME_ROOT=$(mktemp -d "${BATS_TEST_TMPDIR}/xdgrun.XXXXXX")
}

reset_args() {
  _SUBCMD=
  _SUBCMD_GIVEN=
  _ARGS=()
  _SUBCMD_OPTS=()
  _OPT_CONFIG=
  _OPT_HELP=
  _OPT_VERSION=
  _VERBOSE=0
  _QUIET=
  _NO_COLOR=
}

@test "cli: 引数なしは status になる" {
  reset_args
  _parse_args
  [ "$_SUBCMD" = 'status' ]
  [ -z "$_SUBCMD_GIVEN" ]
}

@test "cli: サブコマンドと引数を分けて解析する" {
  reset_args
  _parse_args start db-prod redis-stg
  [ "$_SUBCMD" = 'start' ]
  [ "${_ARGS[0]}" = 'db-prod' ]
  [ "${_ARGS[1]}" = 'redis-stg' ]
}

@test "cli: --config は値付きと = 形式の両方を受け付ける" {
  reset_args
  _parse_args --config /tmp/a.yaml status
  [ "$_OPT_CONFIG" = '/tmp/a.yaml' ]
  reset_args
  _parse_args --config=/tmp/b.yaml status
  [ "$_OPT_CONFIG" = '/tmp/b.yaml' ]
  reset_args
  _parse_args -c /tmp/c.yaml status
  [ "$_OPT_CONFIG" = '/tmp/c.yaml' ]
}

@test "cli: オプションはサブコマンドの前後どちらでも良い" {
  reset_args
  _parse_args status --exit-code -q db-prod
  [ "$_SUBCMD" = 'status' ]
  [ "$_QUIET" = 'yes' ]
  [ "${_SUBCMD_OPTS[0]}" = '--exit-code' ]
  [ "${_ARGS[0]}" = 'db-prod' ]
}

@test "cli: -v は重ねられ、-vv は 2 になる" {
  reset_args
  _parse_args -v status
  [ "$_VERBOSE" -eq 1 ]
  reset_args
  _parse_args -v -v status
  [ "$_VERBOSE" -eq 2 ]
  reset_args
  _parse_args -vv status
  [ "$_VERBOSE" -eq 2 ]
}

@test "cli: -- 以降はすべて引数として扱う" {
  reset_args
  _parse_args stop -- --weird-name
  [ "$_SUBCMD" = 'stop' ]
  [ "${_ARGS[0]}" = '--weird-name' ]
}

@test "cli: --run-as は値を伴って収集される" {
  reset_args
  _parse_args install-service --system --run-as komori --now
  [ "${_SUBCMD_OPTS[0]}" = '--system' ]
  [ "${_SUBCMD_OPTS[1]}" = '--run-as' ]
  [ "${_SUBCMD_OPTS[2]}" = 'komori' ]
  [ "${_SUBCMD_OPTS[3]}" = '--now' ]
}

@test "cli: 未知オプションは終了コード 2" {
  run "$PFWD" --bogus status
  [ "$status" -eq 2 ]
  [[ "$output" == *'unknown option: --bogus'* ]]
}

@test "cli: 未知サブコマンドは終了コード 2" {
  run "$PFWD" bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *'unknown subcommand: bogus'* ]]
}

@test "cli: version と help が動く" {
  run "$PFWD" version
  [ "$status" -eq 0 ]
  [[ "$output" == 'pfwd '* ]]
  run "$PFWD" --version
  [ "$status" -eq 0 ]
  run "$PFWD" help
  [ "$status" -eq 0 ]
  [[ "$output" == 'usage: pfwd'* ]]
  run "$PFWD" help start
  [ "$status" -eq 0 ]
  [[ "$output" == 'usage: pfwd start'* ]]
  run "$PFWD" --help
  [ "$status" -eq 0 ]
  [[ "$output" == 'usage: pfwd <subcommand>'* ]]
}

@test "cli: 名前省略時 start は enabled なエントリのみを対象にする" {
  load_config "${FIXTURES}/basic.yaml"
  _CFG[metrics.enabled]=false
  _SUBCMD=start
  _ARGS=()
  _resolve_names
  [ "${#_TARGETS[@]}" -eq 2 ]
  [ "${_TARGETS[0]}" = 'db-prod' ]
  [ "${_TARGETS[1]}" = 'redis-stg' ]
}

@test "cli: 名前省略時 stop / status は全エントリを対象にする" {
  load_config "${FIXTURES}/basic.yaml"
  _CFG[metrics.enabled]=false
  _SUBCMD=stop
  _ARGS=()
  _resolve_names
  [ "${#_TARGETS[@]}" -eq 3 ]
}

@test "cli: 存在しないエントリ名は終了コード 2 でエラーになる" {
  run "$PFWD" --config "${FIXTURES}/basic.yaml" status db-pord
  [ "$status" -eq 2 ]
  [[ "$output" == *"no such entry 'db-pord'"* ]]
}

@test "cli: デーモン未起動の start は終了コード 5" {
  XDG_RUNTIME_DIR=$RUNTIME_ROOT run "$PFWD" --config "${FIXTURES}/basic.yaml" start db-prod
  [ "$status" -eq 5 ]
  [[ "$output" == *'daemon is not running'* ]]
}

@test "cli: デーモン未起動の stop / restart / reload も終了コード 5" {
  local SUB
  for SUB in stop restart reload; do
    XDG_RUNTIME_DIR=$RUNTIME_ROOT run "$PFWD" --config "${FIXTURES}/basic.yaml" "$SUB"
    [ "$status" -eq 5 ]
  done
}

@test "cli: status はデーモン未起動でも 0 を返す" {
  XDG_RUNTIME_DIR=$RUNTIME_ROOT run "$PFWD" --config "${FIXTURES}/basic.yaml" --no-color status
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'daemon: not running' ]
  [[ "${lines[1]}" == NAME* ]]
}

@test "cli: status --exit-code は未接続があれば 4 を返す" {
  XDG_RUNTIME_DIR=$RUNTIME_ROOT run "$PFWD" --config "${FIXTURES}/basic.yaml" --no-color status --exit-code
  [ "$status" -eq 4 ]
}

@test "cli: status の列が揃っている" {
  XDG_RUNTIME_DIR=$RUNTIME_ROOT run "$PFWD" --config "${FIXTURES}/basic.yaml" --no-color status
  local HEADER=${lines[1]} ROW=${lines[2]}
  # 各列の開始位置がヘッダと一致すること
  local COL
  for COL in 12 24 41 70 82; do
    [ "${HEADER:$COL:1}" != ' ' ]
    [ "${ROW:$COL:1}" != ' ' ]
  done
  [[ "$ROW" == 'db-prod     stopped     127.0.0.1:15432  db.internal:5432'* ]]
}

@test "cli: status の集計行が状態ごとの内訳を出す" {
  XDG_RUNTIME_DIR=$RUNTIME_ROOT run "$PFWD" --config "${FIXTURES}/basic.yaml" --no-color status
  [[ "${lines[-1]}" == '3 entries: 3 stopped' ]]
}

@test "cli: --quiet はエラー以外の出力を抑止する" {
  XDG_RUNTIME_DIR=$RUNTIME_ROOT run "$PFWD" --config "${FIXTURES}/basic.yaml" -q start db-prod
  [ "$status" -eq 5 ]
  [[ "$output" == *'daemon is not running'* ]]
}

@test "cli: _show_result の書式が SPECS 6.3 に一致する" {
  _NAME_WIDTH=10
  run _show_result OK db-prod 'connected (127.0.0.1:15432 -> db.internal:5432)'
  [ "$output" = '[  OK  ] db-prod    connected (127.0.0.1:15432 -> db.internal:5432)' ]
  run _show_result FAILED metrics 'ssh: connect timed out'
  [ "$output" = '[FAILED] metrics    ssh: connect timed out' ]
  run _show_result SKIP redis-stg 'already connected'
  [ "$output" = '[ SKIP ] redis-stg  already connected' ]
  run _show_result WARN metrics 'local port 19090 already in use'
  [ "$output" = '[ WARN ] metrics    local port 19090 already in use' ]
}

@test "cli: _fmt_uptime の整形" {
  [ "$(_fmt_uptime 0)" = '00:00' ]
  [ "$(_fmt_uptime 322)" = '00:05' ]
  [ "$(_fmt_uptime 19320)" = '05:22' ]
  [ "$(_fmt_uptime 187860)" = '2d 04:11' ]
  [ "$(_fmt_uptime 86400)" = '1d 00:00' ]
}

@test "cli: _truncate の整形" {
  local OUT
  [ "$(_truncate 'short' 10)" = 'short' ]
  OUT=$(_truncate 'komori@stg-bastion.example.com' 26)
  [ "$OUT" = 'komori@stg-bastion.exam...' ]
  [ "${#OUT}" -eq 26 ]
}

@test "cli: list の列が揃っている" {
  run "$PFWD" --config "${FIXTURES}/basic.yaml" --no-color list
  [ "$status" -eq 0 ]
  local HEADER=${lines[0]} ROW=${lines[1]}
  local COL
  for COL in 12 21 50 67; do
    [ "${HEADER:$COL:1}" != ' ' ]
    [ "${ROW:$COL:1}" != ' ' ]
  done
}

# --- test サブコマンド --------------------------------------------------------

@test "test: 設定ファイルのパスと 1 行 1 エントリの結果を出す" {
  XDG_RUNTIME_DIR=$RUNTIME_ROOT run "$PFWD" --config "${FIXTURES}/test_cmd.yaml" --no-color test
  [ "$status" -eq 4 ]
  [[ "${lines[0]}" == "Config: ${FIXTURES}/test_cmd.yaml" ]]
  [[ "$output" == *'[FAILED] unreachable'* ]]
  [[ "$output" == *'ssh unreachable'* ]]
  [[ "$output" == *'[FAILED] broken'* ]]
  [[ "$output" == *"missing required key 'remote_port'"* ]]
  [[ "${lines[-1]}" == '0 passed, 0 warning, 2 failed' ]]
}

@test "test: 名前を指定すると当該エントリだけを検査する" {
  XDG_RUNTIME_DIR=$RUNTIME_ROOT run "$PFWD" --config "${FIXTURES}/test_cmd.yaml" --no-color test broken
  [ "$status" -eq 4 ]
  [[ "$output" != *'unreachable'* ]]
  [[ "${lines[-1]}" == '0 passed, 0 warning, 1 failed' ]]
}

@test "test: 検証エラーの警告を二重に出さない" {
  XDG_RUNTIME_DIR=$RUNTIME_ROOT run "$PFWD" --config "${FIXTURES}/test_cmd.yaml" --no-color test
  [ "$(grep -c 'missing required key' <<<"$output")" -eq 1 ]
}

# --- config --system ----------------------------------------------------------

@test "cli: config --system を --init 無しで使うと終了コード 2 になる" {
  run "$PFWD" config --system
  [ "$status" -eq 2 ]
  [[ "$output" == *"'--system' requires '--init'"* ]]
  [[ "$output" == *'usage:'* ]]
}

@test "cli: 非 Linux の config --init --system は終了コード 1 で何も作らない" {
  [ "$(uname)" = 'Linux' ] && skip 'Linux では実際にシステム設定を作りに行く'
  local XDG="${BATS_TEST_TMPDIR}/nonlinux-xdg"
  run env XDG_CONFIG_HOME="$XDG" "$PFWD" config --init --system
  [ "$status" -eq 1 ]
  [[ "$output" == *'Linux (systemd) only'* ]]
  [[ "$output" == *"(uname: $(uname))"* ]]
  [[ "$output" != *'Created:'* ]]
  # 既定パスにフォールバックして作ってしまわないこと
  [ ! -e "${XDG}/port-forwarder/config.yaml" ]
}

@test "cli: --system を付けない config --init は従来どおり警告を出さない" {
  local XDG="${BATS_TEST_TMPDIR}/plain-xdg"
  run env XDG_CONFIG_HOME="$XDG" "$PFWD" config --init
  [ "$status" -eq 0 ]
  [[ "$output" == *"Created: ${XDG}/port-forwarder/config.yaml"* ]]
  [[ "$output" != *'WARN'* ]]
}

# --- install-service ----------------------------------------------------------

@test "service: user unit の内容が DESIGN 5.10 に一致する" {
  run _service_unit_text user '' '/usr/local/bin/pfwd daemon'
  [[ "$output" == *'ExecStart=/usr/local/bin/pfwd daemon'* ]]
  [[ "$output" == *'ExecReload=/bin/kill -HUP $MAINPID'* ]]
  [[ "$output" == *'Restart=on-failure'* ]]
  [[ "$output" == *'RestartSec=10'* ]]
  [[ "$output" == *'KillMode=mixed'* ]]
  [[ "$output" == *'After=network-online.target'* ]]
  [[ "$output" == *'WantedBy=default.target'* ]]
  [[ "$output" != *'User='* ]]
}

@test "service: system unit には User と multi-user.target が入る" {
  run _service_unit_text system komori '/usr/local/bin/pfwd daemon'
  [[ "$output" == *'User=komori'* ]]
  [[ "$output" == *'WantedBy=multi-user.target'* ]]
}

@test "service: macOS では install-service / uninstall-service はエラーになる" {
  [ "$(uname)" = 'Darwin' ] || skip 'macOS 以外では対象外'
  run "$PFWD" --config "${FIXTURES}/basic.yaml" install-service
  [ "$status" -eq 1 ]
  [[ "$output" == *'Linux (systemd) only'* ]]
  run "$PFWD" --config "${FIXTURES}/basic.yaml" uninstall-service
  [ "$status" -eq 1 ]
}
