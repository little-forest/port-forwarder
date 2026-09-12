#!/usr/bin/env bats

load helper

setup() {
  setup_pfwd
  _YQ_IMPL=
  _YQ_VERSION=
  # helper.bash が外す errexit をこのファイルでは有効に戻す。
  # ここで呼ぶのは値を返さない関数だけなので、アサーションの失敗を確実に拾える
  set -e
}

# yq スタブを置いたディレクトリを作り、その PATH を返す
#   make_yq_stub <スクリプト本体>
make_yq_stub() {
  local DIR="${BATS_TEST_TMPDIR}/stub"
  mkdir -p "$DIR"
  printf '#!/bin/sh\n%s\n' "$1" >"${DIR}/yq"
  chmod +x "${DIR}/yq"
  printf '%s\n' "$DIR"
}

#-------------------------------------------------------------------------------
# _yq_kind (型名の正規化)
#-------------------------------------------------------------------------------
@test "yq_kind: mikefarah の YAML タグを正規化する" {
  [ "$(_yq_kind '!!map')" = 'map' ]
  [ "$(_yq_kind '!!seq')" = 'seq' ]
  [ "$(_yq_kind '!!str')" = 'str' ]
  [ "$(_yq_kind '!!bool')" = 'bool' ]
  [ "$(_yq_kind '!!null')" = 'null' ]
  [ "$(_yq_kind '!!int')" = 'number' ]
  [ "$(_yq_kind '!!float')" = 'number' ]
}

@test "yq_kind: jq の型名を正規化する" {
  [ "$(_yq_kind 'object')" = 'map' ]
  [ "$(_yq_kind 'array')" = 'seq' ]
  [ "$(_yq_kind 'string')" = 'str' ]
  [ "$(_yq_kind 'boolean')" = 'bool' ]
  [ "$(_yq_kind 'null')" = 'null' ]
  [ "$(_yq_kind 'number')" = 'number' ]
}

@test "yq_kind: 空出力は null とみなす" {
  [ "$(_yq_kind '')" = 'null' ]
}

@test "yq_kind: 未知の型名はそのまま返す" {
  [ "$(_yq_kind 'weird')" = 'weird' ]
}

#-------------------------------------------------------------------------------
# _yq_is_map / _yq_is_null
#-------------------------------------------------------------------------------
@test "yq_is_map: マップのときだけ真になる" {
  _yq_is_map '!!map'
  _yq_is_map 'object'
  ! _yq_is_map '!!seq'
  ! _yq_is_map 'array'
  ! _yq_is_map '!!str'
  ! _yq_is_map 'string'
  ! _yq_is_map '!!null'
  ! _yq_is_map 'null'
  ! _yq_is_map '!!int'
  ! _yq_is_map 'number'
  ! _yq_is_map '!!bool'
  ! _yq_is_map 'boolean'
  ! _yq_is_map ''
}

@test "yq_is_null: null と空文字のときだけ真になる" {
  _yq_is_null '!!null'
  _yq_is_null 'null'
  _yq_is_null ''
  ! _yq_is_null '!!map'
  ! _yq_is_null 'object'
  ! _yq_is_null '!!seq'
  ! _yq_is_null 'array'
  ! _yq_is_null '!!str'
  ! _yq_is_null 'string'
  ! _yq_is_null '!!int'
  ! _yq_is_null 'number'
  ! _yq_is_null '!!bool'
  ! _yq_is_null 'boolean'
}

#-------------------------------------------------------------------------------
# _yq_detect (実装の判定)
#-------------------------------------------------------------------------------
@test "yq_detect: mikefarah 形式を go と判定する" {
  local DIR
  DIR=$(make_yq_stub 'echo "yq (https://github.com/mikefarah/yq/) version v4.53.3"')
  PATH="${DIR}:${PATH}" _yq_detect
  [ "$_YQ_IMPL" = 'go' ]
  [ "$_YQ_VERSION" = 'mikefarah/yq v4.53.3' ]
}

@test "yq_detect: v の付かない旧 mikefarah 形式も go と判定する" {
  local DIR
  DIR=$(make_yq_stub 'echo "yq (https://github.com/mikefarah/yq/) version 4.25.3"')
  PATH="${DIR}:${PATH}" _yq_detect
  [ "$_YQ_IMPL" = 'go' ]
  [ "$_YQ_VERSION" = 'mikefarah/yq 4.25.3' ]
}

@test "yq_detect: kislyuk 形式 (2 行) を python と判定する" {
  local DIR
  DIR=$(make_yq_stub 'echo "yq 4.1.2"; echo "jq-1.8.2"')
  PATH="${DIR}:${PATH}" _yq_detect
  [ "$_YQ_IMPL" = 'python' ]
  [ "$_YQ_VERSION" = 'kislyuk/yq 4.1.2 (jq-1.8.2)' ]
}

@test "yq_detect: kislyuk 形式 (1 行) も python と判定する" {
  local DIR
  DIR=$(make_yq_stub 'echo "yq 2.14.0"')
  PATH="${DIR}:${PATH}" _yq_detect
  [ "$_YQ_IMPL" = 'python' ]
  [ "$_YQ_VERSION" = 'kislyuk/yq 2.14.0' ]
}

@test "yq_detect: yq v3 は unknown と判定する" {
  local DIR
  DIR=$(make_yq_stub 'echo "yq version 3.4.1"')
  PATH="${DIR}:${PATH}" _yq_detect
  [ "$_YQ_IMPL" = 'unknown' ]
  [ "$_YQ_VERSION" = 'yq version 3.4.1' ]
}

@test "yq_detect: 素性の分からない出力は unknown と判定する" {
  local DIR
  DIR=$(make_yq_stub 'echo "something else entirely"')
  PATH="${DIR}:${PATH}" _yq_detect
  [ "$_YQ_IMPL" = 'unknown' ]
  [ "$_YQ_VERSION" = 'something else entirely' ]
}

@test "yq_detect: 判定は終了しない (yq が非 0 で終了しても戻り値 0)" {
  local DIR RC
  DIR=$(make_yq_stub 'echo "yq version 3.4.1"; exit 1')
  # yq 自身の終了コードは見ない仕様なので、errexit を外して戻り値だけを取る
  set +e
  PATH="${DIR}:${PATH}" _yq_detect
  RC=$?
  set -e
  [ "$RC" -eq 0 ]
  [ "$_YQ_IMPL" = 'unknown' ]
}

@test "yq_detect: 2 回呼んでも yq の起動は 1 回だけ" {
  local DIR="${BATS_TEST_TMPDIR}/counted"
  mkdir -p "$DIR"
  cat >"${DIR}/yq" <<EOF
#!/bin/sh
echo call >> "${DIR}/count"
echo "yq 4.1.2"
echo "jq-1.8.2"
EOF
  chmod +x "${DIR}/yq"
  : >"${DIR}/count"
  PATH="${DIR}:${PATH}" _yq_detect
  PATH="${DIR}:${PATH}" _yq_detect
  [ "$(wc -l <"${DIR}/count")" -eq 1 ]
  [ "$_YQ_IMPL" = 'python' ]
}

#-------------------------------------------------------------------------------
# _yq_diagnose (失敗時の切り分け)
#-------------------------------------------------------------------------------
@test "yq_diagnose: mikefarah なら終了せず 0 を返す" {
  local DIR
  DIR=$(make_yq_stub 'echo "yq (https://github.com/mikefarah/yq/) version v4.53.3"')
  PATH="${DIR}:${PATH}" _yq_diagnose
  [ "$?" -eq 0 ]
}

@test "yq_diagnose: jq のある kislyuk なら終了せず 0 を返す" {
  local DIR
  DIR=$(make_yq_stub 'echo "yq 4.1.2"; echo "jq-1.8.2"')
  printf '#!/bin/sh\nexit 0\n' >"${DIR}/jq"
  chmod +x "${DIR}/jq"
  PATH="${DIR}:${PATH}" _yq_diagnose
  [ "$?" -eq 0 ]
}

@test "yq_diagnose: jq が無ければ終了コード 7" {
  local DIR OUT RC
  DIR=$(make_yq_stub 'echo "yq 4.1.2"; echo "jq-1.8.2"')
  # jq だけが見つからない PATH にする (スタブの yq しか置いていない)
  __SILENT=
  set +e
  OUT=$( PATH="$DIR"; _yq_diagnose 2>&1 )
  RC=$?
  set -e
  [ "$RC" -eq 7 ]
  [[ "$OUT" == *"required command 'jq' not found"* ]]
}

@test "yq_diagnose: 未知の実装なら終了コード 7" {
  local DIR
  DIR=$(make_yq_stub 'echo "yq version 3.4.1"; exit 1')
  set +e
  run env PATH="${DIR}:${PATH}" "$PFWD" list -c "${FIXTURES}/basic.yaml"
  set -e
  [ "$status" -eq 7 ]
  [[ "$output" == *"unsupported yq implementation: yq version 3.4.1"* ]]
}

#-------------------------------------------------------------------------------
# 正常系では実装判定が走らない (決定 #6 の核心)
#-------------------------------------------------------------------------------
@test "yq: 正常時は --version を一度も起動しない" {
  local DIR="${BATS_TEST_TMPDIR}/counted2" REAL
  REAL=$(command -v yq)
  mkdir -p "$DIR"
  cat >"${DIR}/yq" <<EOF
#!/bin/sh
if [ "\$1" = "--version" ]; then echo call >> "${DIR}/count"; fi
exec "$REAL" "\$@"
EOF
  chmod +x "${DIR}/yq"
  : >"${DIR}/count"
  run env PATH="${DIR}:${PATH}" "$PFWD" list -c "${FIXTURES}/basic.yaml"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"${DIR}/count")" -eq 0 ]
}

@test "yq: version / help は yq を一切起動しない" {
  local DIR="${BATS_TEST_TMPDIR}/counted3"
  mkdir -p "$DIR"
  cat >"${DIR}/yq" <<EOF
#!/bin/sh
echo call >> "${DIR}/count"
exit 1
EOF
  chmod +x "${DIR}/yq"
  : >"${DIR}/count"
  run env PATH="${DIR}:${PATH}" "$PFWD" version
  [ "$status" -eq 0 ]
  run env PATH="${DIR}:${PATH}" "$PFWD" help
  [ "$status" -eq 0 ]
  [ "$(wc -l <"${DIR}/count")" -eq 0 ]
}

#-------------------------------------------------------------------------------
# test サブコマンドの yq: 行
#-------------------------------------------------------------------------------
@test "yq: test の出力に yq 行が出る" {
  local DIR="${BATS_TEST_TMPDIR}/testline" REAL
  REAL=$(command -v yq)
  mkdir -p "$DIR"
  cat >"${DIR}/yq" <<EOF
#!/bin/sh
if [ "\$1" = "--version" ]; then
  echo "yq 4.1.2"
  echo "jq-1.8.2"
  exit 0
fi
exec "$REAL" "\$@"
EOF
  chmod +x "${DIR}/yq"
  set +e
  run env PATH="${DIR}:${PATH}" "$PFWD" test -c "${FIXTURES}/basic.yaml"
  set -e
  [[ "$output" == *"yq:     kislyuk/yq 4.1.2 (jq-1.8.2)"* ]]
}
