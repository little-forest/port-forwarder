#!/usr/bin/env bats

load helper

setup() {
  setup_pfwd
}

@test "config: --config で指定したファイルを採用する" {
  _OPT_CONFIG="${FIXTURES}/basic.yaml"
  _config_find
  [ "$_CONFIG_FILE" = "${FIXTURES}/basic.yaml" ]
}

@test "config: XDG_CONFIG_HOME が /etc より優先される" {
  local DIR
  DIR=$(mktemp -d "${BATS_TEST_TMPDIR}/xdg.XXXXXX")
  mkdir -p "${DIR}/port-forwarder"
  cp "${FIXTURES}/basic.yaml" "${DIR}/port-forwarder/config.yaml"
  XDG_CONFIG_HOME=$DIR _OPT_CONFIG= _config_find
  [ "$_CONFIG_FILE" = "${DIR}/port-forwarder/config.yaml" ]
}

@test "config: 設定ファイルが無ければ終了コード 3" {
  run "$PFWD" --config "${BATS_TEST_TMPDIR}/nothing.yaml" list
  [ "$status" -eq 3 ]
  [[ "$output" == *"config file not found"* ]]
}

@test "config: エントリを記述順で読み込む" {
  load_config "${FIXTURES}/basic.yaml"
  [ "${_CFG_NAMES[0]}" = 'db-prod' ]
  [ "${_CFG_NAMES[1]}" = 'redis-stg' ]
  [ "${_CFG_NAMES[2]}" = 'metrics' ]
  [ "${#_CFG_NAMES[@]}" -eq 3 ]
}

@test "config: スカラー値を読み込む" {
  load_config "${FIXTURES}/basic.yaml"
  [ "${_CFG[db-prod.host]}" = 'bastion.example.com' ]
  [ "${_CFG[db-prod.local_port]}" = '15432' ]
  [ "${_CFG[db-prod.remote_host]}" = 'db.internal' ]
  [ "${_CFG[db-prod.description]}" = 'production db tunnel' ]
}

@test "config: ssh_options を配列として読み込む" {
  load_config "${FIXTURES}/basic.yaml"
  local IFS=$'\x1f'
  local OPTS=()
  read -r -a OPTS <<<"${_CFG_OPTS[metrics]}"
  [ "${#OPTS[@]}" -eq 2 ]
  [ "${OPTS[0]}" = 'ExitOnForwardFailure=yes' ]
  [ "${OPTS[1]}" = 'Compression=yes' ]
}

@test "config: 既定値を適用する" {
  load_config "${FIXTURES}/basic.yaml"
  [ "${_CFG[redis-stg.port]}" = '22' ]
  [ "${_CFG[redis-stg.bind_address]}" = '127.0.0.1' ]
  [ "${_CFG[redis-stg.enabled]}" = 'true' ]
  [ "${_CFG[redis-stg.check_mode]}" = 'remote' ]
  [ "${_CFG[redis-stg.check_interval]}" = '30' ]
  [ "${_CFG[metrics.remote_host]}" = 'prom.internal' ]
  [ "${_GLOBAL[retry_limit]}" = '0' ]
  [ "${_GLOBAL[server_alive_interval]}" = '15' ]
}

@test "config: global 未指定時に既定値が入る" {
  load_config "${FIXTURES}/dup_port.yaml"
  [ "${_GLOBAL[check_interval]}" = '30' ]
  [ "${_GLOBAL[connect_timeout]}" = '10' ]
  [ "${_GLOBAL[retry_initial]}" = '5' ]
  [ "${_GLOBAL[retry_max]}" = '300' ]
}

@test "config: conf.d を名前順にマージする" {
  load_config "${FIXTURES}/merge/config.yaml"
  [ "${#_CONFIG_FILES[@]}" -eq 3 ]
  [[ "${_CONFIG_FILES[1]}" == *'10-first.yaml' ]]
  [[ "${_CONFIG_FILES[2]}" == *'20-second.yml' ]]
}

@test "config: global はキー単位で後勝ちする" {
  load_config "${FIXTURES}/merge/config.yaml"
  [ "${_GLOBAL[check_interval]}" = '15' ]
  [ "${_GLOBAL[connect_timeout]}" = '20' ]
}

@test "config: entries はエントリ単位で置換される" {
  load_config "${FIXTURES}/merge/config.yaml"
  # 20-second.yml の metrics は remote_host / user / ssh_options を持たないため既定に戻る
  [ "${_CFG[metrics.host]}" = 'new-bastion.example.com' ]
  [ "${_CFG[metrics.remote_host]}" = 'localhost' ]
  [ -z "${_CFG_OPTS[metrics]}" ]
  # db-prod は上書きされない
  [ "${_CFG[db-prod.host]}" = 'bastion.example.com' ]
}

@test "config: 表示順は初出順を維持する" {
  load_config "${FIXTURES}/merge/config.yaml"
  [ "${_CFG_NAMES[0]}" = 'db-prod' ]
  [ "${_CFG_NAMES[1]}" = 'metrics' ]
  [ "${_CFG_NAMES[2]}" = 'extra-a' ]
  [ "${_CFG_NAMES[3]}" = 'extra-b' ]
}

@test "config: ~ を HOME に展開する" {
  [ "$(_expand_tilde '~/foo')" = "${HOME}/foo" ]
  [ "$(_expand_tilde '~')" = "${HOME}" ]
  [ "$(_expand_tilde '/abs/path')" = '/abs/path' ]
  [ "$(_expand_tilde '~user/foo')" = '~user/foo' ]
}

@test "config: identity の ~ を展開する" {
  local DIR
  DIR=$(mktemp -d "${BATS_TEST_TMPDIR}/home.XXXXXX")
  touch "${DIR}/key"
  chmod 600 "${DIR}/key"
  cat > "${BATS_TEST_TMPDIR}/identity.yaml" <<YAML
entries:
  with-key:
    host: bastion.example.com
    local_port: 15432
    remote_port: 5432
    identity: ~/key
YAML
  HOME=$DIR load_config "${BATS_TEST_TMPDIR}/identity.yaml"
  [ "${_CFG[with-key.identity]}" = "${DIR}/key" ]
  [ -z "${_CFG_INVALID[with-key]}" ]
}

@test "config: yq_edge: null と \"null\" を区別する" {
  load_config "${FIXTURES}/yq_edge.yaml"
  set -e
  # log_file: ~ は空として扱う
  [ -z "${_GLOBAL[log_file]}" ]
  # 文字列 "null" は空に化けない
  [ "${_CFG[nullish.description]}" = 'null' ]
}

@test "config: yq_edge: タブを含む値でもエントリは有効なまま" {
  load_config "${FIXTURES}/yq_edge.yaml"
  set -e
  [ -z "${_CFG_INVALID[tabbed]}" ]
  [ "${_CFG[tabbed.description]}" = $'tab\there' ]
}

@test "config: yq_edge: global に配列があっても後続のキーが読める" {
  load_config "${FIXTURES}/yq_edge.yaml"
  set -e
  [ "${_GLOBAL[connect_timeout]}" = '20' ]
  [ "${_GLOBAL[retry_initial]}" = '7' ]
}

@test "config: yq_edge: 複数行の値はエントリを無効にし、幽霊エントリを作らない" {
  load_config "${FIXTURES}/yq_edge.yaml"
  set -e
  [[ "${_CFG_INVALID[multiline]}" == *"contains a newline"* ]]
  # 継続行がエントリ名として登録されていないこと
  [ "${#_CFG_NAMES[@]}" -eq 4 ]
  local N
  for N in "${_CFG_NAMES[@]}"; do
    [[ "$N" != *' '* ]]
  done
  # _CFG_INVALID にも継続行由来のキーが無いこと
  [ "${#_CFG_INVALID[@]}" -eq 1 ]
}

@test "config: 値に 0x1f を含むとエントリが無効になる" {
  # YAML の二重引用符スカラーでは \uXXXX エスケープで制御文字を書ける
  local F="${BATS_TEST_TMPDIR}/us.yaml"
  cat >"$F" <<'YAML'
entries:
  us:
    description: "a\u001Fb"
    host: h
    local_port: 15001
    remote_port: 5001
YAML
  load_config "$F"
  set -e
  [[ "${_CFG_INVALID[us]}" == *"contains a 0x1f character"* ]]
}

@test "config: conf.d に空ファイルがあっても読み込みは成功する" {
  local DIR="${BATS_TEST_TMPDIR}/emptyconf"
  mkdir -p "${DIR}/conf.d"
  cp "${FIXTURES}/basic.yaml" "${DIR}/config.yaml"
  : >"${DIR}/conf.d/empty.yaml"
  load_config "${DIR}/config.yaml"
  set -e
  [ "${#_CFG_NAMES[@]}" -eq 3 ]

  run "$PFWD" --config "${DIR}/config.yaml" list
  [ "$status" -eq 0 ]
}

@test "config: list が設定内容を表示する" {
  run "$PFWD" --config "${FIXTURES}/basic.yaml" list
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == NAME*ENABLED*SSH*LOCAL*REMOTE ]]
  [[ "${lines[1]}" == db-prod*yes*komori@bastion.example.com*127.0.0.1:15432*db.internal:5432 ]]
}

@test "config: config --init が雛形を生成し、二重生成はエラーになる" {
  local TARGET="${BATS_TEST_TMPDIR}/new/config.yaml"
  run "$PFWD" --config "$TARGET" config --init
  [ "$status" -eq 0 ]
  [[ "$output" == *"Created: ${TARGET}"* ]]
  [ -f "$TARGET" ]
  run "$PFWD" --config "$TARGET" config --init
  [ "$status" -eq 1 ]
  [[ "$output" == *'already exists'* ]]
  run "$PFWD" --config "$TARGET" config --init --force
  [ "$status" -eq 0 ]
}

@test "config: 生成した雛形は妥当な設定として読める" {
  local TARGET="${BATS_TEST_TMPDIR}/tmpl/config.yaml"
  run "$PFWD" --config "$TARGET" config --init
  [ "$status" -eq 0 ]
  run "$PFWD" --config "$TARGET" list
  [ "$status" -eq 0 ]
  [[ "$output" == *'example'* ]]
}

@test "config: config --init に位置引数を渡すと終了コード 2 で拒否される" {
  local TARGET="${BATS_TEST_TMPDIR}/pos/x.yaml"
  local XDG="${BATS_TEST_TMPDIR}/pos-xdg"
  run env XDG_CONFIG_HOME="$XDG" "$PFWD" config --init "$TARGET"
  [ "$status" -eq 2 ]
  [[ "$output" == *"'config' takes no arguments"* ]]
  # 指定先にも既定パスにもファイルが作られていないこと
  [ ! -e "$TARGET" ]
  [ ! -e "${XDG}/port-forwarder/config.yaml" ]
}

@test "config: 引数なしの config に位置引数を渡しても終了コード 2 になる" {
  run "$PFWD" config "${BATS_TEST_TMPDIR}/x.yaml"
  [ "$status" -eq 2 ]
  [[ "$output" == *"'config' takes no arguments"* ]]
}

@test "config: 保存先がディレクトリなら --force の有無によらずエラーになる" {
  local DIR="${BATS_TEST_TMPDIR}/asdir"
  mkdir -p "$DIR"
  run "$PFWD" --config "$DIR" config --init
  [ "$status" -eq 1 ]
  [[ "$output" == *"${DIR} is a directory"* ]]
  # --force でも cat > <dir> に到達せず同じエラーになること
  run "$PFWD" --config "$DIR" config --init --force
  [ "$status" -eq 1 ]
  [[ "$output" == *"${DIR} is a directory"* ]]
}

@test "config: 既定外パスに作成すると Note 行が出る" {
  local TARGET="${BATS_TEST_TMPDIR}/note/pfwd.yaml"
  run "$PFWD" --config "$TARGET" config --init
  [ "$status" -eq 0 ]
  [[ "$output" == *"Note: this path is not searched automatically"* ]]
  [[ "$output" == *"--config ${TARGET}"* ]]
}

@test "config: 既定パスに作成すると Note 行は出ない" {
  local XDG="${BATS_TEST_TMPDIR}/default-xdg"
  run env XDG_CONFIG_HOME="$XDG" "$PFWD" config --init
  [ "$status" -eq 0 ]
  [[ "$output" == *"Created: ${XDG}/port-forwarder/config.yaml"* ]]
  [[ "$output" != *'Note:'* ]]
}

# --- config --init --system ---------------------------------------------------

@test "config: _config_init_target が --system でシステム設定パスを返す" {
  [ "$(uname)" = 'Linux' ] || skip 'Linux 以外では --system がエラーになる'
  local TARGET
  TARGET=$(_config_init_target yes)
  [ "$TARGET" = "$_SYSTEM_CONFIG" ]
}

@test "config: _config_init_target は -c を --system より優先し、警告を出す" {
  # 警告は setup_pfwd の __SILENT=yes で抑制されるため、ここだけ解除する
  __SILENT=
  _OPT_CONFIG="${BATS_TEST_TMPDIR}/mine.yaml"
  # run は既定で stderr を output に混ぜるため、警告の検証は分離して行う
  run --separate-stderr _config_init_target yes
  [ "$status" -eq 0 ]
  [ "$stdout" = "${BATS_TEST_TMPDIR}/mine.yaml" ]
  [[ "$stderr" == *'--system is ignored because --config was given'* ]]
}

@test "config: _config_init_target は --system 無しなら従来どおり利用者パスを返す" {
  local XDG="${BATS_TEST_TMPDIR}/tgt-xdg"
  local TARGET
  TARGET=$(XDG_CONFIG_HOME="$XDG" _config_init_target '')
  [ "$TARGET" = "${XDG}/port-forwarder/config.yaml" ]
}

@test "config: システム設定パスに作成すると Note 行は出ない" {
  # _SYSTEM_CONFIG を一時ディレクトリへ差し替え、root なしで検証する
  local SAVED=$_SYSTEM_CONFIG
  _SYSTEM_CONFIG="${BATS_TEST_TMPDIR}/etc/port-forwarder/config.yaml"
  run _config_init "$_SYSTEM_CONFIG" ''
  _SYSTEM_CONFIG=$SAVED
  [ "$status" -eq 0 ]
  [[ "$output" == *"Created: ${BATS_TEST_TMPDIR}/etc/port-forwarder/config.yaml"* ]]
  [[ "$output" != *'Note:'* ]]
}

@test "config: 書き込めないパスでは Created を出さずエラー終了する" {
  [ "$EUID" -ne 0 ] || skip 'root では書き込み権限チェックが効かない'
  local DIR="${BATS_TEST_TMPDIR}/ro"
  mkdir -p "$DIR"
  chmod 500 "$DIR"
  run "$PFWD" --config "${DIR}/config.yaml" config --init
  chmod 700 "$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *'cannot write the config file'* ]]
  [[ "$output" != *'Created:'* ]]
  # bash 自身のリダイレクトエラーが漏れていないこと
  [[ "$output" != *'Permission denied'* ]]
  [ ! -e "${DIR}/config.yaml" ]
}

@test "config: ディレクトリを作れないパスでは mkdir のエラーで終了する" {
  [ "$EUID" -ne 0 ] || skip 'root では書き込み権限チェックが効かない'
  local DIR="${BATS_TEST_TMPDIR}/ro-mkdir"
  mkdir -p "$DIR"
  chmod 500 "$DIR"
  run "$PFWD" --config "${DIR}/sub/config.yaml" config --init
  chmod 700 "$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot create the directory: ${DIR}/sub"* ]]
  [[ "$output" != *'Created:'* ]]
}
