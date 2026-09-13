---
title: 一時ディレクトリのベースパスを `__TMP_BASE` に一元化する
created: 2026-09-13
updated: 2026-09-13
status: 実装済み
---

# 要求

## 2026-09-13 最初の要求

```text
pfwd で、__get_tmp_base と __script_end_clean_tmp のベースディレクトリ取得ロジックが重複している問題を解決したい。
__script_end_clean_tmp は、trap で呼び出されるため、グローバル変数でベースディレクトリを共有できないことが問題だと考えていますが、他に良い方法はある？
```

## 2026-09-13 追加

```text
ファイルスコープで確定する案を詳しく解説して
```

```text
今の方針を feature-design スキルで設計ドキュメントにして
```

```text
いまの設計をドキュメント化して
```

---

# 設計: 一時ディレクトリのベースパスの一元化

## 目的

一時ディレクトリのベースパスの決定を **`__TMP_BASE` 1 か所に集約**し、生成側（`__make_tmp`）と削除側
（`__script_end_clean_tmp`）が構造的に食い違えないようにする。

**ユーザーから見て変わること**: macOS で `/dev/shm` が存在する環境において、`pfwd` の終了後に一時
ディレクトリが消えずに残る不具合が解消される。

**変わらないこと**: サブコマンドの出力・終了コード・設定ファイルの解釈は一切変わらない。一時
ディレクトリの置き場所の選択規則（RAM ディスク優先、無ければ `$TMPDIR`）も変わらない。外部仕様
（`docs/SPECS_ja.md`）に記述のある振る舞いは 1 つも動かない。

## 現状（出発点）

### 読んだ既存設計文書

| 文書 | 状態 |
| --- | --- |
| `docs/DESIGN_ja.md` | 存在。内部設計書（`ARCHITECTURE.md` 相当）。2.1 基本規約の「一時ファイル」行（59 行）と共通基盤関数表（83-84 行）、3.1 セクション構成（124 行）、2.2「外部コマンド起動はデーモンのループ内では極力避ける」、8 章 性能設計、9 章 セキュリティ設計（`umask 077`）が今回の設計を縛る |
| `docs/SPECS_ja.md` | 存在。外部仕様の正典。**一時ディレクトリに関する記述は 1 行も無い**（`一時` / `tmp` / `TMPDIR` / `/dev/shm` で該当なし）。したがって今回の変更は外部仕様に触れない |
| `docs/SPECS.md` | 上記の英訳。日本語版に従属（`CLAUDE.md`「Handling Documentation」） |
| `ARCHITECTURE.md` / `SPECS.md`（リポジトリ直下） | **無い**。`docs/` 配下の上記 3 本がその役割を担う |

`SPECS_ja.md` は `SPEC-xxx` 形式の ID 体系を持たないため、以降は節番号で名指す。

### 現在の配線

```bash
# pfwd:195-206
__get_tmp_base() {
  local TMP_BASE RAMDISK
  if [[ `uname` != Darwin ]]; then RAMDISK='/dev/shm'; else RAMDISK='/Volumes/Ramdisk'; fi
  [[ -d ${RAMDISK} ]] && TMP_BASE=${RAMDISK}/ || TMP_BASE=${TMPDIR:-/tmp}/
  TMP_BASE="${TMP_BASE}tmp.`basename "$0"`.$$"
  [[ ! -d "$TMP_BASE" ]] && mkdir "$TMP_BASE"      # ← パス計算に mkdir の副作用が同居している
  echo "$TMP_BASE"
}

# pfwd:220-227
__script_end_clean_tmp() {
  local TMP_BASE
  TMP_BASE="${TMPDIR:-/tmp}/tmp.`basename "$0"`.$$"   # ← 同じパスを別のロジックで組み立て直している
  [[ -d /dev/shm ]] && TMP_BASE="/dev/shm/tmp.`basename "$0"`.$$"
  [[ -d /Volumes/Ramdisk ]] && TMP_BASE="/Volumes/Ramdisk/tmp.`basename "$0"`.$$"
  [[ -d "$TMP_BASE" ]] && rm -rf "${TMP_BASE}"
  return 0
}
```

| 経路 | 誰が通るか | 今回どうするか |
| --- | --- | --- |
| `__get_tmp_base` (`pfwd:195-206`) | `__make_tmp` のみ（`pfwd:212`、コマンド置換） | パス計算と `mkdir` を分離し、アクセサにする |
| `__make_tmp` (`pfwd:209-217`) | `_config_parse_file` (`pfwd:639`) のみ。kislyuk/yq 経路で yq の stderr を受けるため | `__TMP_BASE` を直接見る。`mkdir` はここで行う |
| `__script_end_clean_tmp` (`pfwd:220-227`) | `__script_end` (`pfwd:164-170`) が `trap EXIT` から自動収集して呼ぶ | `__TMP_BASE` を直接見る |

### 問題の構造

同じパスを 2 通りの手順で計算しているため、次の 2 つが起きている。

1. **判定ロジックが一致していない。** `__get_tmp_base` は `uname` でプラットフォームを見て RAM ディスクを
   1 つに絞るが、`__script_end_clean_tmp` はプラットフォームを見ず `/dev/shm` → `/Volumes/Ramdisk` の
   順に上書きする。macOS で `/dev/shm` を用意している環境では、生成側が `$TMPDIR` を選び削除側が
   `/dev/shm` を見るため、**一時ディレクトリが消えずに残る**
2. **無駄なフォークが発生する。** `basename` × 4 と `uname` × 1。`docs/DESIGN_ja.md` 2.2 の「外部コマンド
   起動は極力避ける」に反する

### 共有ボイラープレートとの関係

`__` で始まる共通基盤関数は `~/dotfiles/template/script.sh` を出自とするコピーで、`~/bin/archive`、
`~/bin/photo-import`、`~/bin/lzh2bz2`、`~/bin/youtube-download.sh`、`~/dotfiles/utils/sync-scripts` も
同じコードを持つ。自動同期の仕組みは無く、コピーで配られている。

出自であるテンプレート側は次の形で、**重複していない**（`~/dotfiles/template/script.sh:126-131`）。

```bash
__script_end_clean_tmp() {
  local TMP_BASE
  TMP_BASE=`__get_tmp_base`     # ← 共有できている
  [[ -d "$TMP_BASE" ]] && rm -rf "${TMP_BASE}"
}
```

つまり **pfwd 側だけがインライン展開する形に分岐し、その際に判定ロジックがずれた**のが今回の問題の
出どころ。ただしテンプレート版をそのまま戻すのは適切でない。`__get_tmp_base` が `mkdir` を伴うため、
**終了のたびに一時ディレクトリを作ってから消す**ことになり、`pfwd status` のような一時ファイルを
一切使わない実行でも RAM ディスク上にディレクトリが作られる。pfwd でインライン展開したのは、おそらく
これを避けるためだったと読める。

### 誤っていた前提

要求にある「trap で呼び出されるためグローバル変数で共有できない」は成り立たない。**EXIT trap は同一
プロセス内で実行される**ので、スクリプトのトップレベルで代入したグローバルは trap ハンドラから普通に
見える。現に `__SCRIPT_NAME`（`pfwd:21`）がその形で、`_err_*` 群（`pfwd:432-447`）から参照されている。

実際の障害は **コマンド置換のサブシェル** である。

- `pfwd:639` `_YQ_ERR_FILE=$(__make_tmp)`
- `pfwd:212` ``TMP_BASE=`__get_tmp_base` ``

これらの中でグローバルに代入しても、子プロセスの中の話なので親には残らない。ただし **失われるのは変数
への書き込みだけで、`mkdir` したディレクトリの実体はファイルシステムに残る**。したがってパスを先に
確定しておけば、生成をサブシェルに任せたまま親の trap が後片付けできる。

### 既にあって使えるもの

| もの | 使い方 |
| --- | --- |
| `__SCRIPT_NAME` (`pfwd:21`) | ファイルスコープで確定するグローバルの先例であり、置き場所そのもの。`basename "$0"` の再計算をやめてこれを使う |
| `__script_end` (`pfwd:164-170`) | `__script_end_*` を名前で自動収集して `trap EXIT` から呼ぶ機構。そのまま使う |
| `umask 077` (`pfwd:2887`) | 実行時ディレクトリの権限（`docs/DESIGN_ja.md` 9 章）。`mkdir` の権限はこれに乗る |
| `test/helper.bash:19` の `trap - EXIT` | bats が pfwd を source した後に trap を外している。テスト終了時に `__script_end_clean_tmp` は走らない |
| `docs/design/` の既存設計書 2 本 | 出力先とファイル名の規約（`<slug>_ja.md`） |

## 決定

| # | 論点 | 決定 | 理由 |
| --- | --- | --- | --- |
| 1 | ベースパスをどこで決めるか | ファイルスコープのグローバル `__TMP_BASE` で確定する。置き場所は `pfwd:20-23`「common global variables」ブロックの `__SCRIPT_NAME` の直後 | 障害は trap ではなくコマンド置換のサブシェル（「誤っていた前提」）。トップレベルで確定すれば親が値を保持でき、サブシェル側は `mkdir` の実体だけを残せばよい。`__SCRIPT_NAME` が同じ形で機能している実績がある |
| 2 | ディレクトリの生成をどこで行うか | `__make_tmp` に遅延させる。ファイルスコープではパス文字列を決めるだけで `mkdir` しない | 一時ファイルを使わない実行（`pfwd status` / `list` / `up` など、`__make_tmp` の唯一の呼び出し元は kislyuk/yq 経路の `_config_parse_file`）でディレクトリを作らないため。テンプレート版の「終了のたびに作って消す」を避ける |
| 3 | プラットフォーム判定の方法 | `uname` をやめ、`/dev/shm` → `/Volumes/Ramdisk` → `${TMPDIR:-/tmp}` の順に `[[ -d ]]` で見る | 決定 #1 によりファイルスコープは**毎回**評価されるので、フォークを増やせない。判定の実体は「どちらの RAM ディスクが存在するか」でしかなく、`/dev/shm` は macOS にまず無く `/Volumes/Ramdisk` は Linux にまず無いので、組み込みの `-d` テスト 2 回で等価に決まる（`docs/DESIGN_ja.md` 2.2） |
| 4 | `__get_tmp_base` を残すか | 残す。`echo "$__TMP_BASE"` だけのアクセサにする | `__` 共通基盤は `~/dotfiles/template/script.sh` 由来の共有ボイラープレートで、他 5 本以上のスクリプトが同じ関数名を持つ。シグネチャを保てば、この修正を後からテンプレートへ戻せる |
| 5 | スクリプト名の取得 | `basename "$0"` をやめ `__SCRIPT_NAME` を使う | 同じ値を 4 回フォークして求め直していた。`pfwd:21` で確定済み |
| 6 | `mkdir` の失敗検査 | `\|\| return 1` を追加する | 現状は失敗を握り潰しており、直後の `mktemp -p` が分かりにくいエラーを出すだけだった。`docs/DESIGN_ja.md` 2.2「異常系は関数の戻り値で表現し、呼び出し側で必ず判定する」 |
| 7 | 権限指定 | `mkdir -m 700` を明示する | `umask 077`（`pfwd:2887`）は main 側で設定されるため、関数定義だけを読み込む経路や umask 設定前の呼び出しでも 0700 を保証するため。`docs/DESIGN_ja.md` 9 章の方針と一致 |
| 8 | 変数の命名 | `__TMP_BASE`（`__` + 大文字スネークケース） | `docs/DESIGN_ja.md` 2.1「共通基盤由来は `__` + 大文字」 |
| 9 | 出自のテンプレートへの逆伝搬 | **今回は行わない。** pfwd リポジトリ内に閉じる | ユーザー確認済み。決定 #4 によりシグネチャ互換は保たれるので、後から別件として反映できる |
| 10 | 推測可能なパスへの対処 | **今回は行わない** | ユーザー確認済み。現状から変わらない挙動であり、所有者検査（`[[ -O ]]`）を入れると `__make_tmp` の失敗経路が新設され、`_YQ_ERR_FILE` が空文字列になって `2>"$_YQ_ERR_FILE"` が ambiguous redirect になる。フォールバック経路の設計が要るため別論点として分離する |
| 11 | テストを足すか | `test/test_tmp.bats` を新設する | 現在これらの関数には自動テストが 1 つも無い。決定 #1 によりパスが変数になるため、テストから `__TMP_BASE` を差し替えれば安全に生成・削除を検証できる（関数内で計算していた現状では不可能だった） |

## 変更点

### 1. `pfwd` ─ `pfwd:20-23` に `__TMP_BASE` を追加

`__SCRIPT_NAME` の直後、「common global variables」ブロック内に置く（決定 #1 / #3 / #5 / #8）。

```bash
__SCRIPT_NAME=$(basename "$0")

# Temporary directory for this process. The path is fixed here, at script scope,
# so that both __make_tmp (which may run inside a command substitution) and
# __script_end_clean_tmp (which runs from the EXIT trap) agree on it.
# The directory itself is created lazily by __make_tmp.
# Plain -d tests instead of uname: this is evaluated on every run, including the
# ones that never need a temporary file.
if [[ -d /dev/shm ]]; then
  __TMP_BASE="/dev/shm/tmp.${__SCRIPT_NAME}.$$"
elif [[ -d /Volumes/Ramdisk ]]; then
  __TMP_BASE="/Volumes/Ramdisk/tmp.${__SCRIPT_NAME}.$$"
else
  __TMP_BASE="${TMPDIR:-/tmp}/tmp.${__SCRIPT_NAME}.$$"
fi
```

### 2. `pfwd` ─ `pfwd:195-228` の 3 関数を `__TMP_BASE` 参照に置き換える

```bash
__get_tmp_base() {                # 決定 #4: 共有ボイラープレート互換のためのアクセサ
  echo "$__TMP_BASE"
}

__make_tmp() {
  # 決定 #2 / #6 / #7
  [[ -d "$__TMP_BASE" ]] || mkdir -m 700 "$__TMP_BASE" || return 1
  local OPT=()
  [[ "$1" == '-d' ]] && OPT+=("$1")
  OPT+=('-p' "$__TMP_BASE")
  mktemp "${OPT[@]}"
}

__script_end_clean_tmp() {
  [[ -d "$__TMP_BASE" ]] && rm -rf "$__TMP_BASE"
  return 0
}
```

`__make_tmp` に付いている `# shellcheck disable=SC2120` のコメント（`pfwd:209`）はそのまま残す。

### 3. `test/test_tmp.bats` ─ 新規（決定 #11）

`__TMP_BASE` を `$BATS_TEST_TMPDIR` 配下に差し替えたうえで検証する。コメントは日本語（`CLAUDE.md`）。

- `__TMP_BASE` が空でなく、絶対パスであること
- `__get_tmp_base` の出力が `__TMP_BASE` と一致すること（生成側と削除側が同じ値を見ている保証）
- `__make_tmp` がディレクトリを作り、その中にファイルを作ること。権限が `700` であること
- `__make_tmp` をコマンド置換（サブシェル）越しに呼んでも、親から `$__TMP_BASE` でそのディレクトリに
  到達できること（**今回の設計の核心**）
- `__script_end_clean_tmp` がそのディレクトリを消すこと
- `__make_tmp` を一度も呼んでいない状態で `__script_end_clean_tmp` を呼んでも、0 を返し何も壊さないこと

## 触らないもの

| 触らないもの | 理由 |
| --- | --- |
| `~/dotfiles/template/script.sh` と他 5 本以上のスクリプト | 決定 #9。リポジトリをまたぐ変更になる。決定 #4 でシグネチャ互換を保つので後から反映できる |
| 一時ディレクトリの置き場所の選択規則（RAM ディスク優先） | 今回は重複の解消が目的。選択規則そのものは妥当で、変える理由が無い |
| パスが推測可能である点 | 決定 #10。失敗経路の設計が別途必要 |
| `_YQ_ERR_FILE` (`pfwd:460`, `pfwd:639-647`) の使い方 | `__make_tmp` の唯一の呼び出し元だが、戻り値の扱いは現状のまま。決定 #10 で失敗経路を作らないため変更不要 |
| `docs/SPECS_ja.md` / `docs/SPECS.md` | 一時ディレクトリは外部仕様に一切現れない。外から見える振る舞いが変わらない |
| `__script_end` の自動収集機構 (`pfwd:164-170`) | 正しく動いており、今回の問題とは無関係 |
| `install.sh` | 一時ディレクトリを使わない。bash 3.2 制約とも無関係 |

## 実装手順

変更するファイルは `pfwd` 1 本と新規テスト 1 本のみで、層をまたがず総変更量も数十行に収まるため、
フェーズには分割しない。

1. `pfwd:20-23` に `__TMP_BASE` の決定ロジックを追加する（変更点 1）
2. `pfwd:195-228` の 3 関数を書き換える（変更点 2）
3. `bash -n pfwd` と `shellcheck -x -s bash pfwd install.sh` を通す
4. `test/test_tmp.bats` を追加する（変更点 3）
5. `bats test/` 全体を通す
6. 「検証」節の手動確認を macOS で実施する

## 検証

### 自動

| 対象 | 確認すること |
| --- | --- |
| `bash -n pfwd` | 構文エラーが無いこと |
| `shellcheck -x -s bash pfwd install.sh` | **0 件を維持**すること（`CLAUDE.md`）。抑止コメントを増やさないこと |
| `bats test/test_tmp.bats` | 変更点 3 の各項目。特にサブシェル越しの生成が親から見えること |
| `bats test/` | **既存テストが 1 つも壊れないこと。** 特に `test_config.bats` / `test_yq.bats`（`__make_tmp` の唯一の呼び出し元が設定解析経路にある） |
| `PFWD_IT=1 bats test/test_integration.bats` | デーモンの起動・停止が変わらないこと（`pfwd:2510` の `exec` による再起動が絡むため） |

### 手動

1. `./pfwd status` を実行する。→ 終了後に `ls -d /dev/shm/tmp.pfwd.* /Volumes/Ramdisk/tmp.pfwd.* "${TMPDIR:-/tmp}"/tmp.pfwd.* 2>/dev/null` が
   **何も出ないこと**（決定 #2 の確認。一時ファイルを使わない経路ではディレクトリが作られない）
2. kislyuk/yq を PATH に置いた状態で `./pfwd --config test/fixtures/invalid_syntax.yaml test` を実行する。
   → パースエラーのメッセージが従来どおり出て、終了コードが `3`（`_EXIT_CONFIG`）であること
3. 続けて手順 1 と同じ `ls` を実行する。→ **何も残っていないこと**（生成されたディレクトリが削除側に
   届いていることの確認）
4. 実行中にディレクトリが実在することを確かめる:
   `PFWD_SOURCE_ONLY=1 bash -c 'source ./pfwd; F=$(__make_tmp); ls -ld "$__TMP_BASE"; ls -l "$F"; __script_end_clean_tmp; ls -d "$__TMP_BASE" 2>&1'`
   → 権限が `drwx------`、最後の `ls` が「そんなファイルはありません」になること
5. macOS で `sudo mkdir -p /dev/shm` を用意できる環境があれば、その状態で手順 2-3 を繰り返す。
   → **一時ディレクトリが残らないこと**（これが今回直す不具合そのもの。修正前は残る）
6. Linux（`/dev/shm` あり）でも手順 1-4 を実行する。→ ベースが `/dev/shm` 配下に選ばれ、かつ残骸が
   出ないこと
7. `./pfwd up` → `./pfwd status` → `./pfwd down` を通す。→ 出力・終了コードが変更前と同じであること
   （デーモンは `exec` で別プロセスになるため `$$` が変わる。親の一時ディレクトリを子が消していない
   ことを、`up` の後に手順 1 の `ls` で確認する）

## 見送った案

| 案 | 見送った理由 |
| --- | --- |
| テンプレート版（`~/dotfiles/template/script.sh:126-131`）に合わせ、`__script_end_clean_tmp` から `__get_tmp_base` を呼ぶだけにする | 3 行で重複は消せるが、`__get_tmp_base` が `mkdir` を伴うため**終了のたびにディレクトリを作って消す**ことになる。`pfwd status` のような一時ファイルを使わない実行でも RAM ディスクに書き込みが発生し、`uname` + `basename` のフォークも残る |
| `__get_tmp_base` を純粋関数にし（`mkdir` を `__make_tmp` へ移す）、削除側もその関数を呼ぶ | グローバルを増やさず重複も消せる有力案。ただしパスは依然として毎回計算で求まるため、`uname` / `basename` のフォークが残り、終了時にも発生する。また関数内計算のままではテストからパスを差し替えられない（決定 #11）。ファイルスコープ案の方が結果が良い |
| `__get_tmp_base` の中でグローバルにメモ化する | 唯一の呼び出し経路がコマンド置換（`pfwd:212`, `pfwd:639`）なので、サブシェルで書いた値は親に残らない。メモが効かず、毎回再計算になる |
| `__get_tmp_base` を削除し `__TMP_BASE` だけにする | `__` 共通基盤は他 5 本以上のスクリプトと共有するボイラープレート。関数を消すと後からテンプレートへ戻しにくくなる（決定 #4） |
| ファイルスコープで `mktemp -d` を使い、推測不能なパスにする | 一時ファイルを使わない実行でも毎回ディレクトリが作られる。推測可能性への対処は決定 #10 で別論点に分離した |
| `uname` の代わりに `$OSTYPE` を使う | フォークは避けられるが、pfwd 内の他 3 か所（`pfwd:1019`, `pfwd:2720`, `pfwd:2772`）は `uname` でプラットフォームを判定しており、判定方法が 2 種類になる。決定 #3 の `-d` テストならプラットフォーム判定自体が不要になる |

## 実装後に更新する文書

| 文書 | 追記する内容 |
| --- | --- |
| `docs/DESIGN_ja.md` 2.1 基本規約（59 行「一時ファイル」） | ベースパスは `__TMP_BASE` に一元化され、`__make_tmp` が遅延生成し、`__script_end_clean_tmp` が同じ変数を見て削除する、という関係に書き換える |
| `docs/DESIGN_ja.md` 2.1 共通基盤関数表（83-84 行） | `__get_tmp_base` の役割を「`__TMP_BASE` を返すアクセサ」に、`__make_tmp` を「ベースディレクトリを遅延生成して一時ファイルを作る」に改める |
| `docs/DESIGN_ja.md` 3.1 セクション構成（124 行） | セクション 2「common global variables」の例示に `__TMP_BASE` を加える |
| `docs/DESIGN_ja.md` 9 章 セキュリティ設計 | 一時ディレクトリが `0700`（`mkdir -m 700` で umask に依存せず明示）であることを 1 行加える |
| `docs/DESIGN_ja.md` 10.1 テスト構成 | `test/test_tmp.bats` を一覧に加える |
| `docs/SPECS_ja.md` / `docs/SPECS.md` | **更新不要。** 一時ディレクトリは外部仕様に現れず、外から見える振る舞いが変わらない |
| `README.md` / `README_ja.md` | **更新不要。** 同上 |
| この設計書 | `status` を `実装済み` にする |
| （別件）`~/dotfiles/template/script.sh` | 決定 #9 により今回は対象外。この設計の内容を出自へ戻すかは別途判断する。戻す場合は `__TMP_BASE` の追加と 3 関数の置き換えをそのまま適用でき、`__get_tmp_base` のシグネチャが変わらないため既存スクリプトへの影響は無い |
