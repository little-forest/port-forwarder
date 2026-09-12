#!/usr/bin/env bash
# install.sh 用の bats 共通セットアップ
bats_require_minimum_version 1.5.0

PFWD_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export PFWD_ROOT
FIXTURES="${PFWD_ROOT}/test/fixtures"
export FIXTURES
INSTALL_SH="${PFWD_ROOT}/install.sh"
export INSTALL_SH
# PATH を潰すテストがあるため、teardown で戻せるよう退避しておく
ORIG_PATH=$PATH
export ORIG_PATH

# install.sh を関数定義のみ読み込む。
# .bats ファイル内の BASH_SOURCE は bats が前処理した一時ファイルを指すため、
# パス解決はこのヘルパー (実ファイル) 側で行う必要がある
export PFWD_INSTALL_SOURCE_ONLY=1
# shellcheck source=/dev/null
source "$INSTALL_SH"

# グローバル状態を初期化する。各テストの setup から呼ぶ
setup_install() {
  # install.sh は set -e を使わない前提で書かれている (DESIGN 2.2) ため、
  # bats が有効にする errexit を無効化してから関数を呼ぶ
  set +e
  # install.sh は環境変数として読むので export しておく (未設定と同じ扱い)
  export PFWD_INSTALL_DIR=
  export PFWD_VERSION=
  _OS=$(uname)
  _DOWNLOADER=curl
  _TMP_DIR=
  _INSTALL_DIR=
  _REF=
}

# 各テストの teardown から呼ぶ。PATH を壊したまま抜けると bats 自身の
# 後始末 (rm など) が失敗するため必ず戻す
teardown_install() {
  PATH=$ORIG_PATH
}

# ファイルのパーミッションを 3 桁で返す (GNU / BSD 両対応)
perm_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}
