#!/usr/bin/env bats
# install.sh のユニットテスト
# ネットワークには一切触れない。GitHub API のレスポンスは fixtures から与える

load helper_install

setup() {
  setup_install
}

teardown() {
  teardown_install
}

#- _detect_install_dir ---------------------------------------------------------

@test "_detect_install_dir: PFWD_INSTALL_DIR が最優先される" {
  PFWD_INSTALL_DIR=/opt/mybin
  _OS=Darwin
  run _detect_install_dir
  [ "$status" -eq 0 ]
  [ "$output" = '/opt/mybin' ]
}

@test "_detect_install_dir: macOS の既定は ~/.local/bin" {
  _OS=Darwin
  run _detect_install_dir
  [ "$status" -eq 0 ]
  [ "$output" = "${HOME}/.local/bin" ]
}

@test "_detect_install_dir: Linux の既定は /usr/local/bin" {
  _OS=Linux
  run _detect_install_dir
  [ "$status" -eq 0 ]
  [ "$output" = '/usr/local/bin' ]
}

#- _latest_release_tag ---------------------------------------------------------

@test "_latest_release_tag: 最初の tag_name を取り出す" {
  # body 内に紛らわしい tag_name があっても先頭のものを拾うこと
  _fetch_stdout() { cat "${FIXTURES}/release_latest.json"; }
  run _latest_release_tag
  [ "$status" -eq 0 ]
  [ "$output" = 'v1.2.3' ]
}

@test "_latest_release_tag: Release が無ければ失敗する" {
  _fetch_stdout() { cat "${FIXTURES}/release_none.json"; }
  run _latest_release_tag
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "_latest_release_tag: 取得自体に失敗したら失敗する" {
  _fetch_stdout() { return 1; }
  run _latest_release_tag
  [ "$status" -ne 0 ]
}

#- _resolve_ref ----------------------------------------------------------------

@test "_resolve_ref: PFWD_VERSION があれば API を叩かない" {
  PFWD_VERSION=v9.9.9
  _fetch_stdout() { echo 'must not be called'; return 0; }
  run _resolve_ref
  [ "$status" -eq 0 ]
  [ "$output" = 'v9.9.9' ]
}

@test "_resolve_ref: PFWD_VERSION には main も指定できる" {
  PFWD_VERSION=main
  run _resolve_ref
  [ "$status" -eq 0 ]
  [ "$output" = 'main' ]
}

@test "_resolve_ref: Release が無くても main へ縮退しない" {
  _fetch_stdout() { cat "${FIXTURES}/release_none.json"; }
  run _resolve_ref
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

#- _verify ---------------------------------------------------------------------

@test "_verify: 正規の pfwd は 0" {
  run _verify "${PFWD_ROOT}/pfwd"
  [ "$status" -eq 0 ]
}

@test "_verify: 空ファイルは 1" {
  : > "${BATS_TEST_TMPDIR}/empty"
  run _verify "${BATS_TEST_TMPDIR}/empty"
  [ "$status" -eq 1 ]
}

@test "_verify: shebang が違えば 2" {
  printf '#!/bin/sh\n_VERSION=1.0.0\n' > "${BATS_TEST_TMPDIR}/f"
  run _verify "${BATS_TEST_TMPDIR}/f"
  [ "$status" -eq 2 ]
}

@test "_verify: _VERSION が無ければ 3" {
  printf '#!/usr/bin/env bash\necho hi\n' > "${BATS_TEST_TMPDIR}/f"
  run _verify "${BATS_TEST_TMPDIR}/f"
  [ "$status" -eq 3 ]
}

@test "_verify: bash として壊れていれば 4" {
  # 関数が閉じていない = 途中で切れた本文を模したもの
  printf '#!/usr/bin/env bash\n_VERSION=1.0.0\nmain() {\n  echo hi\n' > "${BATS_TEST_TMPDIR}/f"
  run _verify "${BATS_TEST_TMPDIR}/f"
  [ "$status" -eq 4 ]
}

@test "_verify: プロキシのエラーページは弾かれる" {
  printf '<html><body>404 Not Found</body></html>\n' > "${BATS_TEST_TMPDIR}/f"
  run _verify "${BATS_TEST_TMPDIR}/f"
  [ "$status" -eq 2 ]
}

#- _read_version ---------------------------------------------------------------

@test "_read_version: シングルクォートを外して返す" {
  printf "#!/usr/bin/env bash\n_VERSION='1.0.0'\n" > "${BATS_TEST_TMPDIR}/f"
  run _read_version "${BATS_TEST_TMPDIR}/f"
  [ "$output" = '1.0.0' ]
}

@test "_read_version: 実物の pfwd から読める" {
  run _read_version "${PFWD_ROOT}/pfwd"
  [ -n "$output" ]
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

#- _is_writable_dir ------------------------------------------------------------

@test "_is_writable_dir: 書き込めるディレクトリ" {
  run _is_writable_dir "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
}

@test "_is_writable_dir: 未作成でも親が書ければ真" {
  run _is_writable_dir "${BATS_TEST_TMPDIR}/a/b/c"
  [ "$status" -eq 0 ]
}

@test "_is_writable_dir: 親が書けなければ偽" {
  run _is_writable_dir '/proc/nonexistent/bin'
  [ "$status" -ne 0 ]
}

#- _install_bin ----------------------------------------------------------------

@test "_install_bin: 存在しないディレクトリを作って 755 で配置する" {
  local DIR="${BATS_TEST_TMPDIR}/bin"
  run _install_bin "${PFWD_ROOT}/pfwd" "$DIR"
  [ "$status" -eq 0 ]
  [ -x "${DIR}/pfwd" ]
  [ "$(perm_of "${DIR}/pfwd")" = '755' ]
}

@test "_install_bin: 既存ファイルを上書きする" {
  local DIR="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$DIR"
  printf 'old\n' > "${DIR}/pfwd"
  chmod 600 "${DIR}/pfwd"
  run _install_bin "${PFWD_ROOT}/pfwd" "$DIR"
  [ "$status" -eq 0 ]
  [ "$(perm_of "${DIR}/pfwd")" = '755' ]
  run head -n 1 "${DIR}/pfwd"
  [ "$output" = '#!/usr/bin/env bash' ]
}

#- _is_in_path -----------------------------------------------------------------

@test "_is_in_path: PATH に含まれる" {
  PATH="/opt/x:/opt/y:${PATH}"
  run _is_in_path '/opt/y'
  [ "$status" -eq 0 ]
}

@test "_is_in_path: 部分一致では真にならない" {
  PATH='/opt/yellow:/usr/bin'
  run _is_in_path '/opt/y'
  [ "$status" -ne 0 ]
}

#- 依存チェック ----------------------------------------------------------------

@test "_yq_status: mikefarah/yq v4 は 0" {
  yq() { echo 'yq (https://github.com/mikefarah/yq/) version v4.44.1'; }
  run _yq_status
  [ "$status" -eq 0 ]
}

@test "_yq_status: Python 版 yq は 2" {
  yq() { echo 'yq 3.2.3'; }
  run _yq_status
  [ "$status" -eq 2 ]
}

@test "_yq_status: 未インストールは 1" {
  PATH='/nonexistent'
  run _yq_status
  [ "$status" -eq 1 ]
}

@test "_is_bash_ok: bash 3.2 は偽、4.2 以上は真" {
  _bash_version() { echo '3.2'; }
  run _is_bash_ok
  [ "$status" -ne 0 ]

  _bash_version() { echo '4.1'; }
  run _is_bash_ok
  [ "$status" -ne 0 ]

  _bash_version() { echo '4.2'; }
  run _is_bash_ok
  [ "$status" -eq 0 ]

  _bash_version() { echo '5.2'; }
  run _is_bash_ok
  [ "$status" -eq 0 ]
}

@test "_is_bash_ok: バージョンが読めなければ偽" {
  _bash_version() { return 1; }
  run _is_bash_ok
  [ "$status" -ne 0 ]

  _bash_version() { echo 'unknown'; }
  run _is_bash_ok
  [ "$status" -ne 0 ]
}

#- 依存不足はインストールを止めない --------------------------------------------

@test "_check_deps: 依存が全て欠けていても 0 を返す" {
  _is_bash_ok() { return 1; }
  _bash_version() { echo '3.2'; }
  _yq_status() { return 1; }
  PATH='/nonexistent'
  run _check_deps
  [ "$status" -eq 0 ]
  [[ "$output" =~ 'bash 3.2' ]]
  [[ "$output" =~ 'ssh' ]]
  [[ "$output" =~ 'yq' ]]
}

# vim: ts=2 sw=2 sts=2 et nu foldmethod=marker
