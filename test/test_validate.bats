#!/usr/bin/env bats

load helper

setup() {
  setup_pfwd
}

@test "validate: 必須キーの欠落で該当エントリのみ無効になる" {
  load_config "${FIXTURES}/validate.yaml"
  [[ "${_CFG_INVALID[no-remote-port]}" == *"missing required key 'remote_port'"* ]]
  [ -z "${_CFG_INVALID[good]}" ]
}

@test "validate: ポート範囲外で無効になる" {
  load_config "${FIXTURES}/validate.yaml"
  [[ "${_CFG_INVALID[port-out-of-range]}" == *'must be an integer between 1 and 65535'* ]]
}

@test "validate: local_port 重複で両方が無効になる" {
  load_config "${FIXTURES}/dup_port.yaml"
  [[ "${_CFG_INVALID[db-prod]}" == *'used by both [db-prod] and [db-copy]'* ]]
  [[ "${_CFG_INVALID[db-copy]}" == *'used by both [db-prod] and [db-copy]'* ]]
  [ -z "${_CFG_INVALID[other]}" ]
}

@test "validate: 不正なエントリ名は無効になる" {
  load_config "${FIXTURES}/bad_names.yaml"
  [[ "${_CFG_INVALID[this-entry-name-is-far-too-long-to-be-accepted]}" == *'invalid entry name'* ]]
  [[ "${_CFG_INVALID[bad name!]}" == *'invalid entry name'* ]]
  [ -z "${_CFG_INVALID[good.name_1-ok]}" ]
}

@test "validate: 未知キーは警告のみでエントリは有効なまま" {
  load_config "${FIXTURES}/validate.yaml"
  [ -z "${_CFG_INVALID[unknown-key]}" ]
  [ "${_CFG[unknown-key.typo_key]}" = 'whatever' ]
}

@test "validate: check_mode が不正なら無効になる" {
  load_config "${FIXTURES}/validate.yaml"
  [[ "${_CFG_INVALID[bad-mode]}" == *'invalid check_mode'* ]]
}

@test "validate: enabled の各表記を正規化する" {
  load_config "${FIXTURES}/validate.yaml"
  [ "${_CFG[enabled-yes.enabled]}" = 'true' ]
  [ "${_CFG[enabled-zero.enabled]}" = 'false' ]
  [ "${_CFG[good.enabled]}" = 'true' ]
}

@test "validate: enabled が真偽値でなければ無効になる" {
  cat > "${BATS_TEST_TMPDIR}/en.yaml" <<YAML
entries:
  weird:
    host: bastion.example.com
    local_port: 15432
    remote_port: 5432
    enabled: maybe
YAML
  load_config "${BATS_TEST_TMPDIR}/en.yaml"
  [[ "${_CFG_INVALID[weird]}" == *'invalid enabled value'* ]]
}

@test "validate: identity が存在しなければ無効になる" {
  load_config "${FIXTURES}/validate.yaml"
  [[ "${_CFG_INVALID[missing-identity]}" == *'does not exist'* ]]
}

@test "validate: identity の権限が緩ければ無効になる" {
  local KEY="${BATS_TEST_TMPDIR}/loose.key"
  touch "$KEY"
  chmod 644 "$KEY"
  cat > "${BATS_TEST_TMPDIR}/perm.yaml" <<YAML
entries:
  loose:
    host: bastion.example.com
    local_port: 15432
    remote_port: 5432
    identity: ${KEY}
YAML
  load_config "${BATS_TEST_TMPDIR}/perm.yaml"
  [[ "${_CFG_INVALID[loose]}" == *'too open permissions (0644)'* ]]
  chmod 600 "$KEY"
  setup_pfwd
  load_config "${BATS_TEST_TMPDIR}/perm.yaml"
  [ -z "${_CFG_INVALID[loose]}" ]
}

@test "validate: bind_address 0.0.0.0 は警告のみ" {
  cat > "${BATS_TEST_TMPDIR}/bind.yaml" <<YAML
entries:
  wide:
    host: bastion.example.com
    local_port: 15432
    remote_port: 5432
    bind_address: 0.0.0.0
YAML
  load_config "${BATS_TEST_TMPDIR}/bind.yaml"
  [ -z "${_CFG_INVALID[wide]}" ]
}

@test "validate: check_interval は最小 5 に丸められる" {
  cat > "${BATS_TEST_TMPDIR}/interval.yaml" <<YAML
global:
  check_interval: 1
entries:
  a:
    host: bastion.example.com
    local_port: 15432
    remote_port: 5432
    check_interval: 2
YAML
  load_config "${BATS_TEST_TMPDIR}/interval.yaml"
  [ "${_GLOBAL[check_interval]}" = '5' ]
  [ "${_CFG[a.check_interval]}" = '5' ]
}

@test "validate: YAML 構文エラーは終了コード 3" {
  run "$PFWD" --config "${FIXTURES}/invalid_syntax.yaml" list
  [ "$status" -eq 3 ]
  [[ "$output" == *'failed to parse'* ]]
}

@test "validate: entries がマップでなければ終了コード 3" {
  run "$PFWD" --config "${FIXTURES}/entries_not_map.yaml" list
  [ "$status" -eq 3 ]
  [[ "$output" == *"'entries' must be a map"* ]]
}

@test "validate: entries が空なら終了コード 3" {
  run "$PFWD" --config "${FIXTURES}/no_entries.yaml" list
  [ "$status" -eq 3 ]
  [[ "$output" == *'no valid entries'* ]]
}

@test "validate: 無効エントリがあっても他のエントリは処理を継続する" {
  run "$PFWD" --config "${FIXTURES}/validate.yaml" list
  [ "$status" -eq 0 ]
  [[ "$output" == *'good'* ]]
}
