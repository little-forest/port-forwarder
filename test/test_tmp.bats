#!/usr/bin/env bats

load helper

setup() {
  setup_pfwd
  # helper.bash の setup_pfwd が外す errexit をこのファイルでは有効に戻す。
  # bats は errexit が無効だとアサーションの失敗を拾えない
  set -e
  # 実ファイルシステム (/dev/shm や $TMPDIR) を汚さないよう、
  # ベースパスを bats のテスト用一時ディレクトリ配下へ差し替える。
  # 関数内でパスを計算していた頃はこの差し替えができなかった
  __TMP_BASE="${BATS_TEST_TMPDIR}/tmp.pfwd.$$"
}

teardown() {
  [[ -n "$__TMP_BASE" ]] && rm -rf "$__TMP_BASE"
  return 0
}

#-------------------------------------------------------------------------------
# __TMP_BASE (ファイルスコープで確定するベースパス)
#-------------------------------------------------------------------------------
@test "tmp: __TMP_BASE が絶対パスで確定している" {
  # source 時の値を見たいので setup の差し替え前の計算結果を再現する
  local BASE
  # $0 が pfwd 自身になるよう、スクリプトのパスを bash -c の $0 として渡す
  BASE=$(PFWD_SOURCE_ONLY=1 bash -c 'source "$0"; printf "%s" "$__TMP_BASE"' "$PFWD")
  [ -n "$BASE" ]
  [[ "$BASE" == /* ]]
  # スクリプト名と PID を含む
  [[ "$BASE" == *"/tmp.pfwd."* ]]
}

@test "tmp: __TMP_BASE は source した時点ではディレクトリを作らない" {
  local BASE
  BASE=$(PFWD_SOURCE_ONLY=1 bash -c 'source "$0"; printf "%s" "$__TMP_BASE"' "$PFWD")
  [ ! -e "$BASE" ]
}

#-------------------------------------------------------------------------------
# __get_tmp_base (アクセサ)
#-------------------------------------------------------------------------------
@test "tmp: __get_tmp_base は __TMP_BASE をそのまま返す" {
  # 生成側と削除側が同じ値を見ていることの保証
  [ "$(__get_tmp_base)" = "$__TMP_BASE" ]
}

#-------------------------------------------------------------------------------
# __make_tmp (遅延生成)
#-------------------------------------------------------------------------------
@test "tmp: __make_tmp がベースディレクトリと一時ファイルを作る" {
  local F
  # shellcheck disable=SC2119
  F=$(__make_tmp)
  [ -d "$__TMP_BASE" ]
  [ -f "$F" ]
  [[ "$F" == "${__TMP_BASE}/"* ]]
}

@test "tmp: ベースディレクトリの権限が 700 である" {
  local MODE
  # shellcheck disable=SC2119
  __make_tmp >/dev/null
  MODE=$(perm_of "$__TMP_BASE")
  [ "$MODE" = '700' ]
}

@test "tmp: __make_tmp -d はディレクトリを作る" {
  local D
  D=$(__make_tmp -d)
  [ -d "$D" ]
  [[ "$D" == "${__TMP_BASE}/"* ]]
}

@test "tmp: 既にベースディレクトリがあっても __make_tmp は成功する" {
  mkdir -m 700 "$__TMP_BASE"
  # shellcheck disable=SC2119
  run __make_tmp
  [ "$status" -eq 0 ]
  [ -f "$output" ]
}

@test "tmp: ベースディレクトリを作れなければ __make_tmp は 1 を返す" {
  # 同名のファイルを置いて mkdir を失敗させる
  : >"$__TMP_BASE"
  # shellcheck disable=SC2119
  run __make_tmp
  [ "$status" -eq 1 ]
  rm -f "$__TMP_BASE"
}

#-------------------------------------------------------------------------------
# サブシェル越しの生成 (今回の設計の核心)
#-------------------------------------------------------------------------------
@test "tmp: コマンド置換で呼んでも親から __TMP_BASE でディレクトリに届く" {
  local F
  # _config_parse_file の _YQ_ERR_FILE=$(__make_tmp) と同じ形。
  # サブシェルでは変数への書き込みが失われるが、mkdir の実体は残るため
  # 親プロセスの __TMP_BASE でそのディレクトリを指せる
  # shellcheck disable=SC2119
  F=$(__make_tmp)
  [ -d "$__TMP_BASE" ]
  [ -f "$F" ]
  # 親側の trap 経路で削除できる
  __script_end_clean_tmp
  [ ! -e "$__TMP_BASE" ]
}

#-------------------------------------------------------------------------------
# __script_end_clean_tmp (削除)
#-------------------------------------------------------------------------------
@test "tmp: __script_end_clean_tmp が中身ごとベースディレクトリを消す" {
  # shellcheck disable=SC2119
  __make_tmp >/dev/null
  # shellcheck disable=SC2119
  __make_tmp >/dev/null
  [ -d "$__TMP_BASE" ]
  run __script_end_clean_tmp
  [ "$status" -eq 0 ]
  [ ! -e "$__TMP_BASE" ]
}

@test "tmp: __make_tmp を呼んでいなくても __script_end_clean_tmp は 0 を返す" {
  [ ! -e "$__TMP_BASE" ]
  run __script_end_clean_tmp
  [ "$status" -eq 0 ]
  [ ! -e "$__TMP_BASE" ]
}
