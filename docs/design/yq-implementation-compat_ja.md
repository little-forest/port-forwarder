---
title: kislyuk/yq (Python 実装) でも設定ファイルを解析できるようにする
created: 2026-09-12
updated: 2026-09-13
status: 実装中
---

# 要求

## 1. 不具合の報告（2026-09-12）

````text
Linux環境で、pfwd testを実行すると、以下のエラーが出ました。このとき、どんなyqコマンドを実行している?
[ ERROR ] failed to parse ./test.yaml: jq: error: tag/0 is not defined at <top-level>, line 1: .entries | tag            jq: 1 compile error
````

## 2. 修正の依頼（2026-09-12）

````text
yqコマンドが kislyuk/yq でも動作するように修正して
````

## 3. 設計見直しの依頼（2026-09-13）

````text
yqの実装がどちらの場合でも、同じクエリが使えるように、設計を見直してみてください
````

# 設計: 単一のクエリで両実装を賄う

対象ブランチ: `feat/yq-implementation-compat`

## 目的

`yq` が **kislyuk/yq（Python 実装。jq のラッパー）** の環境でも `pfwd` が設定ファイルを解析できるようにする。
RedHat 系の EPEL や `pip install yq` で入る `yq` はこちらであり、現状はすべての設定読み込み系サブコマンドが
終了コード 3 で即死する。

**2026-09-13 の見直しで方針が変わった。** 以前の設計は「Python 実装のときだけ jq クエリに `def tag: …;` を
前置する」という方言吸収だったが、実測の結果、**両実装に同じクエリ文字列をそのまま渡せる**ことが分かった。
したがって実装ごとのクエリ加工は行わず、`pfwd` は **1 本のクエリだけを持つ**。

あわせて、**どちらの実装でも同じ設定ファイルが同じ意味に解釈される**ことを保証する。実装によって
`null` の扱いやタブを含む値の扱いが変わるのでは「動く」と言えないため。

**変わらないもの**: mikefarah/yq 環境での通常の設定ファイル（スカラーとタブ・改行を含まない文字列だけ）
の解釈結果・出力・終了コードは一切変えない。`yq` 呼び出し回数（設定ファイル 1 本あたり 5 回）も増やさない。
**正常時は `yq --version` すら起動しない**（決定 #6）。

## 現状（出発点）

### 読んだ既存設計文書

| 文書 | 状態 |
| --- | --- |
| `docs/SPECS_ja.md` | 存在。外部仕様の正典。2.1 依存コマンド（**「mikefarah/yq v4 以上を前提とする」「バージョンの自動判定は行わない」**）、4.4 検証ルール（YAML 構文エラーは終了コード 3）、6.4 `pfwd test` の出力、10 章 エラーメッセージ方針が今回の設計を縛る |
| `docs/SPECS.md` | 上記の英訳。日本語版に従属（`CLAUDE.md`「Handling Documentation」） |
| `docs/DESIGN_ja.md` | 内部設計書（`ARCHITECTURE.md` 相当）。4.1「yq の呼び出し」（クエリ 0〜4 の一覧）、5 章の `_config_parse_file` 行（361 行）、7.2 依存コマンド検査（849〜852 行）、8 章 起動時間の要件（894 行）、9 章 テスト方針（917 行）が該当 |
| `ARCHITECTURE.md` / `SPECS.md`（リポジトリ直下） | **無い**。`docs/` 配下の上記 3 本がその役割を担う |

`SPECS_ja.md` は `SPEC-xxx` 形式の ID 体系を持たないため、以降は節番号で名指す。

**SPECS 2.1 は「mikefarah/yq v4 系」を明記し、「バージョンの自動判定は行わない」と決めている。**
今回の要求はこの決定の改訂にあたる（新しい振る舞いの追加ではなく、既存仕様の書き換え）。
さらに実測により、**SPECS 2.1 の「v4 以上」という記述自体が現状と合っていない**ことが分かった（下記 #5・#6）。

### 現在の配線

すべて `_config_parse_file`（`pfwd:567`）に閉じている。

| 場所 | 内容 |
| --- | --- |
| `pfwd:575` クエリ 0 | `yq -r '.entries \| tag' FILE`。stderr だけ `_YQ_ERR_FILE` に退避し、非 0 終了なら `_err_parse_failed` で終了コード 3。**報告されたエラーはここ** |
| `pfwd:596` クエリ 1 | エントリ名と値の型。`[.key, (.value \| tag)] \| @tsv` |
| `pfwd:603` クエリ 2 | `global` の全キー。`[.key, .value] \| @tsv`（**型で絞っていない**） |
| `pfwd:619` クエリ 3 | エントリのスカラー値。seq / map を除外して `[$n, .key, .value] \| @tsv` |
| `pfwd:638` クエリ 4 | `ssh_options`（配列）。`[$n, .] \| @tsv` |
| `pfwd:585,599,607,627` 読み取り側 | いずれも `IFS=$'\t' read -r`。**先頭フィールドが空の行は `continue` で捨てている** |
| `pfwd:609-614` | 値にタブが入って列がずれたことを**タブの数で検出**し、そのエントリを無効化する |
| `pfwd:601,617` | `[[ "$VAL" == 'null' ]] && VAL=` で null を空に落とす |
| `pfwd:2788` `_check_prerequisites` | `ssh` と `yq` の存在を `command -v` で確認するだけ。**実装の種類もバージョンも見ない**（DESIGN 7.2 の方針どおり） |
| `pfwd:2881` main dispatch | `test` を含む設定読み込み系はすべて `_check_prerequisites` → `_config_setup` の順に通る |

クエリ 1〜4 は stderr を `/dev/null` に捨て、終了コードも見ていない。つまり **kislyuk 環境ではクエリ 0
で止まるため実害が表面化しているが、仮にクエリ 0 を通っても 1〜4 は黙って空を返す**。

### 実測した実装差

測定日 2026-09-13（macOS / arm64）。使った実装は以下。

- mikefarah/yq: v4.18.1・v4.19.1・v4.21.1・v4.22.1・v4.23.1・v4.24.5・v4.25.3・v4.28.2・v4.31.2・v4.33.3・v4.35.2・v4.44.6・v4.53.3・v4.53.6
- kislyuk/yq: 2.14.0・3.4.3・4.1.2（いずれも jq 1.8.2 と組み合わせ）

#### A. 共通のクエリが書けることの根拠

| # | 事実 | mikefarah/yq | kislyuk/yq (jq) |
| --- | --- | --- | --- |
| A1 | `tag` | `!!map` などを返す | **存在しない**（報告された `tag/0 is not defined`） |
| A2 | **`type`** | **`tag` の別名として存在**し `!!map` を返す。master の `pkg/yqlib/lexer_participle.go:160` が `assignableOp("tag\|type", …)`。v4.25.3〜v4.53.6 の全バージョンで確認 | jq 標準の `type`。`object` / `array` / `string` / `number` / `boolean` / `null` を返す |
| A3 | **リテラルとの型比較** `type == ({} \| type)` | `true`（`{}` / `[]` / `""` / `0` / `null` / `true` のリテラルがすべて評価できる） | `true`。**型名の表記に依存しないので、同じ式が両方で正しく動く** |
| A4 | `to_entries[]`（後置 `[]`） | **v4.35.2 以前は構文エラー**（`Bad expression`）。v4.44.6 以降は通る | 通る |
| A5 | `to_entries \| .[]` | **試したすべてのバージョン（v4.25.3 以降）で通る** | 通る |
| A6 | `.key as $n` を**ストリームに対して**使う | **v4.28.2 以前は誤動作**（`$n` が全キーの連結になり `e-f-host-h` のような行が出る）。v4.31.2 以降は正常 | 正常 |
| A7 | `-r` | **v4.24.5 以前は `unknown shorthand flag: 'r'`**。v4.25.3 以降で使える | jq の `-r` がそのまま効く |

A4・A6・A7 は**今回の変更とは無関係に、現行の `pfwd` が既に要求している下限**である
（現行クエリは `to_entries[]` を使うため、実質 mikefarah v4.44 以降でしか動かない）。
A5 に書き換えると下限が **v4.31** まで下がる。

#### B. 出力の食い違いと、その吸収

| # | 入力 | mikefarah/yq | kislyuk/yq (jq) | 吸収方法 |
| --- | --- | --- | --- | --- |
| B1 | `type` の戻り値表記 | `!!map` / `!!seq` / `!!str` / `!!int` / `!!float` / `!!bool` / `!!null` | `object` / `array` / `string` / `number` / `boolean` / `null` | bash 側で正規化（決定 #3）。`!!int` と `!!float` は `number` に潰れる |
| B2 | タブを含む値を `@tsv` | `"tab<TAB>here"` ── 引用符で囲むがタブは生のまま（列がずれる） | `tab\there` ── `\t` の 2 文字にエスケープ | `join("<0x1f>")` に置き換えると**両実装ともタブを生のまま通す**（決定 #9） |
| B3 | 複数行の値を `@tsv` | 生の改行でレコードが分断される | `\n` にエスケープされ 1 行に収まる | `join` にすると**両実装とも生の改行**になる。区切り数で検出して無効化（決定 #12） |
| B4 | `log_file: ~` / `x: null` を `join` | 空文字 | 空文字 | **一致**。`[[ "$VAL" == 'null' ]] && VAL=` は不要になる（決定 #10） |
| B5 | `k: "null"`（文字列） | `null` | `null` | **一致**。現行コードはこれを空に化けさせている（同 #10 で解消） |
| B6 | 空ファイルに `.entries \| type` | `!!null`（rc=0） | **何も出力しない**（rc=0） | 空出力を `null` とみなす（決定 #3 に内包） |
| B7 | 結果が 0 件のストリーム | **空行を 1 行出す**（`od -c` で `\n` のみ） | 何も出力しない | 読み取り側の `[[ -z "$NAME" ]] && continue` が**既に吸収済み**。`ssh_options` だけは `length > 0` で絞る（決定 #15） |
| B8 | `global` に配列・マップが混ざる | `join` で値が落ちる | 行ごとにエラー終了し、**それ以降のキーも失われる** | クエリ 2 にも seq / map を除く `select` を足す（決定 #13） |
| B9 | `port: 022` / `x: 1.50` / `x: 1e3` | `022` / `1.50` / `1e3`（**原文のまま**） | `22` / `1.5` / `1000.0`（**数値として再フォーマット**） | **吸収しない**（決定 #18）。YAML パーサの差でありクエリでは埋められない |
| B10 | `yes` / `on` / `12:30` | 文字列 `yes` / `on` / `12:30` | **4.x では同じく文字列**。ただし 2.14.0（YAML 1.1）は `true` / `true` / `750` | `_normalize_bool`（`pfwd:690`）が真偽値については既に吸収済み |
| B11 | YAML 構文エラー | `Error: bad file …: yaml: line 4, …` | `yq: Error running jq: ScannerError: …`（rc=1） | 整形せず `_sanitize` して見せる（決定 #16） |
| B12 | `--version` | `yq (https://github.com/mikefarah/yq/) version v4.53.3`（v4.25 以前は `version 4.25.3` と `v` が付かない） | `yq 4.1.2` + `jq-1.8.2` の 2 行。2.14.0 は `yq 2.14.0` の 1 行 | 判定は `mikefarah` の有無と `^yq [0-9]` で行う（決定 #7） |
| B13 | jq 未導入 | ── | `--version` は rc=0 のまま。クエリ実行時に `Is jq installed and available on PATH?` で rc=1 | 失敗時に判定して `_err_no_command jq`（決定 #8） |
| B14 | 複数ドキュメント（`---`） | ドキュメント境界に `---` の行を挟む | 挟まず連結する | **今回対象外**（現行でも未対応） |

#### C. 総合検証

上記の方針で組み立てたクエリ 5 本を、リポジトリの `test/fixtures/*.yaml`（`invalid_syntax.yaml` を除く 7 本）に対して
mikefarah v4.53.6・v4.31.2、kislyuk 4.1.2・3.4.3 の 4 実装で実行し、bash 側の正規化を適用したうえで比較した結果は
**105 件中 差分 0 件**（`invalid_syntax.yaml` は B11 のとおり stderr の文言だけが違う）。

### 既にあって使えるもの

- `_US`（`pfwd:41`、`$'\x1f'`）── 配列要素の区切りとして既に使っている制御文字。`ssh_options` は
  0x1f を含む値を既に拒否している（`pfwd:629`）
- `_err_*` 関数群（`pfwd:433-447`）── エラー文言の集約先。`_err_no_command`（442 行）はそのまま jq にも使える
- `_YQ_ERR_FILE` + `__make_tmp`（`pfwd:210`）+ `_sanitize`（`pfwd:312`）── yq の stderr を安全に見せる経路
- 各ループ先頭の `[[ -z "$NAME" ]] && continue` ── B7 の空行を既に吸収している
- `_normalize_bool`（`pfwd:690`）── B10 のとおり真偽値の差は吸収済み。今回対処不要
- `_check_prerequisites`（`pfwd:2788`）── 設定を読む全サブコマンドが必ず通る一点（ただし決定 #6 により今回は触らない）

## 決定

★ の付いた行は 2026-09-13 の見直しで**以前の決定を覆したもの**。覆された案は「見送った案」に移した。

| # | 論点 | 決定 | 理由 |
| --- | --- | --- | --- |
| 1 ★ | 両実装の吸収方法 | **クエリ文字列は 1 本だけ持ち、実装に関わらずそのまま渡す**。前置きも分岐も持たない | 2026-09-13 の要求。実測 A2・A3 により、実装ごとの加工なしで同じ式が両方で正しく動くことが確認できた。クエリの二重管理も `_YQ_PRELUDE` も不要になる |
| 2 ★ | 型判定の書き方 | クエリ内では**型名の文字列を書かず、リテラルの型と比較**する（`select((.value \| type) == ({} \| type))`） | 実測 B1。`"!!map"` や `"object"` と書いた瞬間に実装依存になる。リテラル同士の比較なら表記が何であれ正しい |
| 3 | 型名の正規化 | 表示と分岐に使う型名は **bash 側**で `map` / `seq` / `str` / `number` / `bool` / `null` に正規化する（`_yq_kind`）。**空出力も `null`** とみなす | **ユーザー確認済み**。メッセージ本文の「must be a map」と語が揃う。空出力を `null` に寄せることで B6（空ファイル）が同時に片付く |
| 4 ★ | 使う演算子 | `tag` をやめ **`type` に統一**する | 実測 A1・A2。`type` は両実装が持つ唯一の共通語。mikefarah 側では `tag` の正式な別名（lexer に `tag\|type` と定義されている）であり、戻り値も `tag` と同一 |
| 5 ★ | `to_entries` の展開 | `to_entries[]` を **`to_entries \| .[]`** に書き換える | 実測 A4・A5。意味は同じで、mikefarah の対応下限が v4.44 → v4.31 に下がる。kislyuk 側は 2.14.0 でも変わらず動く |
| 6 | 実装判定のタイミング | **yq クエリが失敗したときだけ**判定する（`_yq_diagnose`）。`pfwd test` は表示のため常に判定する（`_yq_detect`） | **ユーザー確認済み**。決定 #1 により判定はクエリの組み立てに不要になったので、正常時の `yq --version` 起動が丸ごと不要になる。未知の実装でも jq 互換なら動く方が良い |
| 7 | 未知の実装 | `yq --version` に `mikefarah` を含めば Go 実装、含まず先頭行が `^yq [0-9]` なら Python 実装、それ以外は**未知**として終了コード 7（`_EXIT_DEPS`）で明示エラー | **ユーザー確認済み**（判定タイミングのみ #6 で改訂）。実測 B12。バージョン番号は両者とも 4.x に達していて使えない。`yq read` 構文の v3（`yq version 3.4.1`）は自動的に未知側に落ちる |
| 8 | jq の存在確認 | Python 実装と判定できたときだけ `command -v jq` を確認し、無ければ `_err_no_command jq` で終了コード 7 | 実測 B13。`yq --version` は jq が無くても成功するため、ここで見ないと解析時の生エラーになる |
| 9 | 区切り文字 | 全クエリの `@tsv` を `join("<0x1f>")` に置き換える | **ユーザー確認済み**。実測 B2・B3・B4 のとおり両実装の出力が一致し、タブ・改行・null の食い違いが構造的に消える。0x1f は `_US` として既に同じ役割で使っている |
| 10 | null の扱い | `join` が両実装とも空文字に正規化するのに任せ、`[[ "$VAL" == 'null' ]] && VAL=` は削除する | 決定 #9 の副産物。実測 B4・B5。文字列 `"null"` を書いたときに空へ化ける現行の誤りも同時に消える |
| 11 | タブを含む値 | 列ずれが起きなくなるので「タブを含む値はエントリ無効」という扱いをやめ、値としてそのまま通す | あの無効化（`pfwd:609-614`）は TSV の列ずれ対策であって、タブ自体を禁じる仕様はどこにも無い（SPECS 4.4 に記載なし） |
| 12 | 改行を含む値 | 区切りが 2 個でない行を、3 個以上 → 値に 0x1f が入っている／1 個以下 → **直前の行の値が複数行**、と切り分けて該当エントリを無効化する | 決定 #9 で列ずれの原因が 0x1f と改行だけに絞られる。現行コードは継続行の先頭文字列を**エントリ名だと誤解**して `_CFG_INVALID[line2]` のような幽霊エントリを作るので、ここで直す |
| 13 | `global` のクエリ | クエリ 2 にもクエリ 3 と同じ「seq / map を除く」`select` を足す | 実測 B8。現行の `@tsv` でも global が丸ごと空になっており、どちらにせよ絞り込みが要る |
| 14 | 判定結果の可視化 | `pfwd test` の `Config:` 行の並びに `yq:` の 1 行を足す | **ユーザー確認済み**。環境依存の失敗を切り分ける場所として `test` が適切。`status` / `list` など常用の出力（SPECS 6.1 / 6.2）は変えない |
| 15 | `ssh_options` が無いエントリ | クエリ 4 に `select(((.value.ssh_options // []) \| length) > 0)` を足す | 実測 B7。無くても読み取り側が吸収するが、足すと**両実装の生出力がバイト単位で一致**し、検証（`diff`）が単純になる。`length` と `>` は両実装・全バージョンで確認済み |
| 16 | yq のエラー文言 | 実装ごとに整形せず、これまでどおり stderr を `_sanitize` して見せる | 実測 B11。文言を実装ごとに解釈し始めると yq の更新に追随できなくなる。行番号が含まれる点は両実装で共通（SPECS 4.4） |
| 17 | 対応バージョンの下限 | **mikefarah/yq 4.31 以上**、**kislyuk/yq 2.14 以上（＋ jq 1.5 以上）**とし、SPECS に明記する。ただし**コードでのバージョン検査はしない** | 実測 A5〜A7 で確認できた下限。検査を足しても `--version` の起動が増えるだけで、下回る環境では結局クエリが失敗して決定 #6 の経路に入る。jq 1.5 は `to_entries` / `join` / `//` / `as` があれば足りるという意味（RHEL 8・Debian 10 の同梱が 1.5/1.6） |
| 18 | 数値表記の残差 | `022` / `1.50` / `1e3` のような**正規形でない数値リテラル**の表記差は吸収しない。既知の差として文書化し、文字列として扱いたい値は引用符で囲むよう案内する | 実測 B9。これは YAML パーサの解釈差であり、どんなクエリを書いても埋まらない。`pfwd` が数値として読むキー（ポート番号・各種秒数）はいずれも正規形で書かれる前提で、`port: 022` のような書き方は実害が出る前に SPECS 4.4 の範囲検査に掛かる |

## 変更点

### 1. `pfwd` ─ yq 実装の判定と型名の正規化（config functions ブロックの先頭、`pfwd:459` 付近）

グローバルは 2 本だけ。**`_YQ_PRELUDE` は持たない**（決定 #1）。

```bash
# yq implementation: 'go' (mikefarah/yq), 'python' (kislyuk/yq) or 'unknown'; empty until detected
_YQ_IMPL=
# human readable version, shown by 'pfwd test'
_YQ_VERSION=
```

型名の正規化（決定 #3）。外部コマンドを起動しない純 bash。

```bash
# normalize the output of the yq 'type' operator (mikefarah tags / jq type names)
_yq_kind() {                  # _yq_kind <type output>
  case "$1" in
    '!!map'|object)           printf 'map\n'    ;;
    '!!seq'|array)            printf 'seq\n'    ;;
    '!!null'|null|'')         printf 'null\n'   ;;
    '!!bool'|boolean)         printf 'bool\n'   ;;
    '!!int'|'!!float'|number) printf 'number\n' ;;
    '!!str'|string)           printf 'str\n'    ;;
    *)                        printf '%s\n' "$1" ;;
  esac
}
```

ループの中で `$( )` を起こさないよう、分岐は述語関数で行う（`_is_*` の命名規約に沿う）。

```bash
_yq_is_map()  { [[ "$1" == '!!map'  || "$1" == 'object' ]]; }
_yq_is_null() { [[ -z "$1" || "$1" == '!!null' || "$1" == 'null' ]]; }
```

判定（冪等。決定 #6 #7）。**終了はしない**。`pfwd test` はこれだけを呼ぶ。

```
_yq_detect() {
  [[ -n "$_YQ_IMPL" ]] && return 0
  OUT=$(yq --version 2>&1)          # rc は見ない (kislyuk は jq 不在でも 0)
  case ... in
    *mikefarah*)           _YQ_IMPL=go     ; _YQ_VERSION="mikefarah/yq <ver>" ;;
    先頭行が ^yq [0-9]+\.)  _YQ_IMPL=python ; _YQ_VERSION="kislyuk/yq <ver> (<jq ver>)" ;;
    *)                     _YQ_IMPL=unknown; _YQ_VERSION=$(_sanitize "$OUT" の先頭行) ;;
  esac
  return 0
}
```

失敗時の切り分け（決定 #6 #7 #8）。**yq が非 0 で終了したときにだけ**呼ばれる。

```
_yq_diagnose() {
  _yq_detect
  case "$_YQ_IMPL" in
    python)  command -v jq >/dev/null 2>&1 \
               || _error_exit "$_EXIT_DEPS" "$(_err_no_command jq)" ;;
    unknown) _error_exit "$_EXIT_DEPS" "$(_err_unsupported_yq "$_YQ_VERSION")" ;;
  esac
  return 0      # go 実装、または jq のある python 実装 → 呼び出し元が終了コード 3 で終了する
}
```

### 2. `pfwd` ─ `_config_parse_file`（`pfwd:567-644`）のクエリ

5 本すべてを下表に差し替える（`<US>` は 0x1f のリテラル 1 バイト）。**実装による分岐は無い。**

| # | 目的 | クエリ |
| --- | --- | --- |
| 0 | 構造検証 | `.entries \| type` |
| 1 | エントリ名と値の型 | `(.entries // {}) \| to_entries \| .[] \| [.key, (.value \| type)] \| join("<US>")` |
| 2 | `global` | `(.global // {}) \| to_entries \| .[] \| select((.value\|type) != ([]\|type) and (.value\|type) != ({}\|type)) \| [.key, .value] \| join("<US>")` |
| 3 | エントリのスカラー値 | `(.entries // {}) \| to_entries \| .[] \| select((.value\|type) == ({}\|type)) \| .key as $n \| .value \| to_entries \| .[] \| select((.value\|type) != ([]\|type) and (.value\|type) != ({}\|type)) \| [$n, .key, .value] \| join("<US>")` |
| 4 | `ssh_options` | `(.entries // {}) \| to_entries \| .[] \| select((.value\|type) == ({}\|type)) \| select(((.value.ssh_options // []) \| length) > 0) \| .key as $n \| (.value.ssh_options // []) \| .[] \| [$n, .] \| join("<US>")` |

読み取り側の変更は次のとおり。

- クエリ 0（575 行）: 非 0 終了なら **`_yq_diagnose "$(cat "$_YQ_ERR_FILE")"` を挟んでから** これまでどおり
  `_err_parse_failed` で終了コード 3（決定 #6）。取得した型は `_yq_is_map` / `_yq_is_null` で判定し、
  どちらでもなければ `'entries' must be a map (got $(_yq_kind "$TAG"))`。
- 読み取り側（585 / 599 / 607 / 627 行）: `IFS=$'\t'` → `IFS=$_US`。
- クエリ 1 の型判定（594 行）: `[[ "$TAG" != '!!map' ]]` → `_yq_is_map "$TAG" || _config_invalidate "$NAME" "entry must be a map (got $(_yq_kind "$TAG"))"`。
- 601 / 617 行の `[[ "$VAL" == 'null' ]] && VAL=` を削除（決定 #10）。
- 609-614 行のタブ数判定を 0x1f 数判定（`${LINE//[^$_US]/}`）に置き換え、決定 #12 の切り分けにする。

```
  区切り数 == 2 → 正常
  区切り数 >  2 → 値に 0x1f    → _config_invalidate "$NAME" "value of '<KEY>' contains a 0x1f character"
  区切り数 <  2 → 直前の値が複数行 → _config_invalidate "$LAST_NAME" "value of '<LAST_KEY>' contains a newline"
```

`LAST_NAME` / `LAST_KEY` はループ内で持ち回す（`NAME` を継続行の文字列で上書きしないこと）。
各ループ先頭の `[[ -z "$NAME" ]] && continue` は**そのまま残す**（B7 の空行対策）。

### 3. `pfwd` ─ エラー文言（`pfwd:447` の後）

```bash
_err_unsupported_yq() { echo "unsupported yq implementation: $1. pfwd supports mikefarah/yq 4.31+ (https://github.com/mikefarah/yq) and kislyuk/yq 2.14+ with jq (https://github.com/kislyuk/yq)."; }
```

### 4. `pfwd` ─ `_check_prerequisites`（`pfwd:2788`）

**変更しない。** 決定 #6 により、正常時に `yq --version` を起動しないため、ここに判定を足す理由が無くなった。
`ssh` / `yq` の存在確認だけを従来どおり行う。

### 5. `pfwd` ─ `_cmd_test`（`pfwd:2565` 付近）

`Config:` とその継続行の後、空行の前に 1 行足す（決定 #14）。ここでは `_yq_detect` を必ず呼ぶ。

```
Config: /home/komori/.config/port-forwarder/config.yaml
        /home/komori/.config/port-forwarder/conf.d/work.yaml
yq:     kislyuk/yq 4.1.2 (jq-1.8.2)

[  OK  ] db-prod    config valid, ssh reachable, local port free
```

mikefarah 環境では `yq:     mikefarah/yq v4.53.3`。未知の実装では `yq:     unknown (yq version 3.4.1)`
（`test` は診断コマンドなので、ここでは終了コード 7 で落とさず表示に留める）。

## 触らないもの

| 触らないもの | 理由 |
| --- | --- |
| `_check_prerequisites`（`pfwd:2788`） | 決定 #6。正常経路で `yq --version` を起動しないため、手を入れる必要が無くなった |
| yq の呼び出し回数（設定ファイル 1 本につき 5 回） | DESIGN 8 章の起動時間要件。決定 #1 によりクエリは 1 本で足りるので増減しない |
| `_normalize_bool`（`pfwd:690`） | 実測 B10。真偽値解釈の差は現時点で吸収済み |
| 各ループ先頭の `[[ -z "$NAME" ]] && continue` | 実測 B7 の空行を既に吸収している。決定 #15 と二重の守りになる |
| yq の stderr の見せ方 | 決定 #16。実装ごとの文言整形はしない |
| `status` / `list` / `start` などの出力（SPECS 6.1・6.2・6.3） | 診断行は `test` にだけ足す（決定 #14） |
| 複数ドキュメント（`---` 区切り）の YAML | 実測 B14。現行でもどちらの実装でも正しく扱えていない既知の未対応であり、今回の要求の範囲外 |
| 数値リテラルの表記差 | 決定 #18 |
| `install.sh` | yq を導入しないし、依存チェックは警告のみ。判定ロジックは持ち込まない（bash 3.2 制約もある） |
| yq / jq のバージョン検査 | 決定 #17 |

## フェーズ

| | 内容 | これだけで何が変わるか |
| --- | --- | --- |
| **P1** | 決定 #1〜#5・#17 ─ `_yq_kind` / `_yq_is_map` / `_yq_is_null` を足し、5 本のクエリを `tag` → `type`、`to_entries[]` → `to_entries \| .[]` に書き換える。区切りは `@tsv` のまま | **kislyuk/yq 環境で `pfwd test` / `list` / `status` が通るようになる**（報告された不具合が解消する）。mikefarah の対応下限が 4.44 相当 → 4.31 に下がる。実装判定のコードはまだ入らない |
| **P2** | 決定 #9〜#13・#15 ─ 区切りを 0x1f に統一し、読み取り側の `IFS` と null・列ずれの扱いを直し、クエリ 2 と 4 に `select` を足す | 両実装で**同じ設定ファイルが同じ意味に解釈される**。あわせて mikefarah 環境でも `log_file: ~` が空として扱われ、`global` に配列を書いても他のキーが消えなくなり、タブを含む description でエントリが無効化されなくなる |
| **P3** | 決定 #6〜#8・#14 ─ `_yq_detect` / `_yq_diagnose` / `_err_unsupported_yq` を足し、クエリ 0 の失敗経路に繋ぐ。`pfwd test` に `yq:` 行を足す | 失敗したときの理由が分かるようになる。jq 未導入 → `required command 'jq' not found`（終了コード 7）、mikefarah v3 など → `unsupported yq implementation`（同 7）。利用者が「自分の yq がどちらとして認識されているか」を `test` で確認できる |
| **P4（今回やらない）** | 複数ドキュメント YAML への対応、yq / jq のバージョン検査、`install.sh` での yq 導入支援、数値表記差の吸収 | いずれも要求の範囲外、または原理的に埋まらない（決定 #17・#18、実測 B9・B14）。複数ドキュメントは現行でも未対応で、今回の変更で悪化もしない |

P1 と P2 を分けるのは、P1 だけで要求（kislyuk 環境で動く）を満たせて単体で動作確認できるため。
P2 は既存 mikefarah 利用者の挙動に踏み込む変更なので、切り戻せる形で分けておく。
P3 を最後に置けるのは、決定 #6 により**判定が正常系に一切関与しなくなった**ため（以前の設計では判定が
クエリ組み立ての前提だったので P1 に含める必要があった）。

## 検証

### 自動

kislyuk/yq が入っていない環境でも回るように、**判定ロジックと正規化**を実 yq から切り離して検証する
（DESIGN 9 章の「外部依存は関数で差し替える」方針）。

| 対象 | 確認すること |
| --- | --- |
| `_yq_kind`（新規 `test/test_yq.bats`） | `!!map` / `object` → `map`、`!!seq` / `array` → `seq`、`!!int` / `!!float` / `number` → `number`、`!!null` / `null` / **空文字** → `null`、`!!str` / `string` → `str`、`!!bool` / `boolean` → `bool` |
| `_yq_is_map` / `_yq_is_null` | 上記 6 種＋空文字に対する真偽。`map` 以外で真にならないこと |
| `_yq_detect` | `yq` を PATH の先頭に置いたスタブに差し替え、`--version` が mikefarah 形式 → `_YQ_IMPL=go` / kislyuk 形式（2 行・1 行の両方） → `python` / `yq version 3.4.1` → `unknown` / 不明な文字列 → `unknown`。**いずれの場合も終了しない**こと |
| `_yq_detect`（冪等性） | 2 回呼んでもスタブの起動回数が 1 回であること（スタブにカウンタを持たせる） |
| `_yq_diagnose` | kislyuk 形式のスタブ＋jq の無い PATH → 終了コード 7 と `required command 'jq' not found` / `unknown` → 終了コード 7 と `unsupported yq implementation` / mikefarah 形式 → **終了せず 0 を返す** |
| **正常時に判定が走らないこと** | カウンタ付き `yq` スタブで `pfwd list` 相当を通し、`--version` の起動回数が **0** であること（決定 #6 の核心） |
| `_config_parse_file`（既存 `test/test_config.bats` 22 本） | **全件そのまま通ること**。区切りを 0x1f にしても既存 fixture の解釈結果が変わらないことの確認になる |
| 新規 fixture `test/fixtures/yq_edge.yaml` | `log_file: ~` → `_GLOBAL[log_file]` が空 / `k: "null"` → 文字列 `null` のまま（決定 #10）/ `description` にタブを含むエントリが**有効**（決定 #11）/ `global` に配列キーがあっても後続のキーが読めること（決定 #13）/ 複数行の値を持つエントリが `contains a newline` で無効になり、**幽霊エントリが `_CFG_NAMES` に入らない**こと（決定 #12） |
| 空ファイル | 空の `conf.d/empty.yaml` を含む構成で終了コード 0、エントリ数が変わらないこと（実測 B6） |
| エラーメッセージ | `entries_not_map.yaml` で `'entries' must be a map (got seq)` ── **`!!seq` ではない**こと（決定 #3）。`test/test_validate.bats:128` は前方一致なのでそのまま通る |
| `PFWD_IT=1` の統合テスト | kislyuk/yq が PATH にあるときだけ実行する任意テストを追加し、mikefarah で読んだ結果と kislyuk で読んだ結果（`pfwd list` の出力）が**バイト単位で一致**すること |
| `shellcheck -x -s bash pfwd` | 0 件を維持。クエリ文字列内の `$n` は現行同様シングルクォートで SC2016 を抑止する |

### 手動

kislyuk/yq を入れた環境（`python3 -m venv v && v/bin/pip install yq`、PATH の先頭に `v/bin`）で行う。

1. `yq --version` が `yq 4.x` と `jq-1.x` の 2 行を出すことを確認する
2. `./pfwd test -c ./test.yaml` → **`failed to parse` が出ず**、エントリごとの `[  OK  ]` / `[FAILED]` が並ぶ
3. 同じ出力の 3 行目に `yq:     kislyuk/yq 4.1.2 (jq-1.8.2)` が出る
4. `./pfwd list -c ./test.yaml` の出力を保存する
5. PATH を mikefarah/yq に戻して `./pfwd list -c ./test.yaml` → **手順 4 と 1 バイトも違わない**こと（`diff` で確認）
6. `./pfwd test` の `yq:` 行が `mikefarah/yq v4.53.3` に変わること
7. PATH から jq を外して `./pfwd list` → `error: required command 'jq' not found...`、`echo $?` が 7
8. `yq` を `#!/bin/sh` + `echo "yq version 3.4.1"` のスタブに差し替えて `./pfwd list` → `error: unsupported yq implementation: yq version 3.4.1. pfwd supports ...`、`echo $?` が 7
9. 壊れた YAML（`entries:` の下にインデント不整合）を両実装で `./pfwd test` → どちらも終了コード 3 で、行番号を含む yq のエラーがそのまま出る
10. mikefarah v4.31.2 のバイナリで `./pfwd list` → 4.53 系と同じ出力になること（決定 #5・#17 の下限確認）

### 見えないものの確認

- 手順 5 で、mikefarah 環境の `list` / `status` の出力・終了コードが変更前と**変わっていない**こと
  （変更前のバイナリで取得した出力と `diff`）
- `pfwd status` / `pfwd list` の実行中に起動する外部プロセスが**変更前と同数**であること
  （`yq --version` が 1 回も増えないこと。`PFWD_DEBUG` があれば `set -x`、無ければ
  `strace -f -e trace=execve` / `dtruss` で確認）
- `pfwd version` / `pfwd help` が **`yq` を一切起動しない**こと
- 50 エントリの設定で `pfwd status` が 1 秒以内（DESIGN 8 章）── `_yq_kind` の `$( )` が
  正常系のループに入っていないことの確認を兼ねる

## 見送った案

| 案 | 見送った理由 |
| --- | --- |
| **Python 実装のときだけ `def tag: …;` をクエリに前置する（2026-09-12 の決定 #6）** | 2026-09-13 の見直しで**撤回**。クエリ本体こそ共有できるが、実装ごとに文字列を組み立てる分岐（`_YQ_PRELUDE`）と、その前提としての事前判定が残る。実測 A2・A3 のとおり `type` とリテラル型比較で分岐そのものを消せる |
| **`_check_prerequisites` で必ず実装判定する（同 決定 #4・#5）** | 2026-09-13 の見直しで**撤回**（ユーザー確認済み）。判定がクエリ組み立ての前提でなくなったため、正常時に `yq --version` を起動する理由が無い。未知でも jq 互換なら動く実装を、起動時点で一律に拒否しない方が良い |
| **`tag` を使い続けて `!!map` などの表記で分岐する（現行実装）** | jq に `tag` が無い。文字列 `"!!map"` と比較する書き方は、どちらの実装向けに書いても他方で壊れる |
| `type` の戻り値を jq の語彙（`object` / `array` / …）に寄せる | mikefarah → jq の写像は情報の捏造が無く成立するが、メッセージが「must be a map (got array)」と語が混ざる。ユーザーが `map` / `seq` 系の語彙を選択（決定 #3） |
| `!!map` / `!!seq` の YAML タグ表記のまま正規化する | mikefarah 利用者の見た目は変わらない反面、kislyuk の `number` は `!!int` / `!!float` を区別できないため、数値をすべて `!!int` と偽ることになる。ユーザーが正規化後の語彙を選択（決定 #3） |
| 実装ごとに 5 本ずつ、計 10 本のクエリ表を持つ | 各方言を素直に書ける代わりに、仕様変更のたびに 2 箇所の同期が要る。決定 #1・#2 で 1 本に収まったため不要 |
| `def tag:` を前置するだけで `@tsv` は据え置き | 差分は最小だが、タブ・改行・null の扱いが実装ごとに食い違ったまま残る（実測 B2・B3・B4）。「kislyuk でも動く」と言えない |
| `type` も使わず、両実装が持つ演算子だけで型を判定する（`keys` の成否、`[..] \| length`、`has()` など） | `keys` / `has` は非マップに対して両実装とも**エラー終了**するため、ストリームごと落ちる。`[..] \| length == 1` は空のマップ・空の配列をスカラーと誤判定する。`type` が共通語として存在する以上、回りくどいだけ |
| クエリ 0 を mikefarah 方言で撃ってみて、失敗したら jq 方言で撃ち直す（実装判定なし） | mikefarah 環境で追加コストがゼロという利点はあるが、YAML 構文エラーと方言エラーの区別が付かず、エラー文言が二重に出る。決定 #1 でクエリが 1 本になったため、そもそも撃ち直す相手が無い |
| mikefarah のバージョンを判定し、4.31 未満を終了コード 7 で弾く | 失敗経路でしか判定しないので実装は可能だが、バージョン文字列の表記揺れ（`version 4.25.3` / `version v4.53.3`）を bash で解釈する分岐が増える。下限を下回る環境では yq 自身が `Bad expression` を出し、決定 #6 の経路で `failed to parse` として行番号付きで見える。文書に下限を明記する方（決定 #17）で足りる |
| `yq` をやめて `python3 -c` で YAML を読む | `python3` が新たな必須依存になり、SPECS 2.1 の依存表が増える。yq 前提という既存の設計判断をひっくり返す変更でもある |
| 未知の実装は mikefarah とみなして続行 | ユーザーが終了コード 7 での明示エラーを選択（決定 #7）。今回の報告と同じ「意味の分からない jq のエラー」を再生産するため |
| `pfwd version` に判定結果を出す | ユーザーが `test` を選択。`version` は `_check_prerequisites` を通らない軽量経路であり、ここに判定を足すと `yq` 未導入で `pfwd version` すら失敗しかねない |
| `_normalize_bool` に PyYAML の YAML 1.1 対策を足す | 既に `yes` / `no` / `on` / `off` を受け付けており、対策済みだった（実測 B10） |

## 実装後に更新する文書

**この設計の時点では反映しない。** 日本語版を先に更新し、その後で英訳に反映する（`CLAUDE.md`「Handling Documentation」）。

| 文書 | 追記する内容 |
| --- | --- |
| `docs/SPECS_ja.md` 2.1 依存コマンド（56〜68 行） | 依存表の `yq` 行を「**mikefarah/yq 4.31 以上 または kislyuk/yq 2.14 以上（＋ jq）**」に改める（決定 #17。現在の「v4 以上」は実測と合っていない）。表の直後の「mikefarah/yq v4 以上を前提とする」「バージョンの自動判定は行わない」の段落を、**同一のクエリで両実装に対応し、解析に失敗したときにだけ実装を判定して終了コード 7 で終了する**旨に書き換える。kislyuk/yq のときは `jq` も必須であることを追記。数値リテラルの表記差（決定 #18）を注記し、文字列は引用符で囲むよう案内する |
| `docs/SPECS_ja.md` 4.4 命名・検証ルール（222〜240 行） | 「値に改行または 0x1f を含むキーがあるエントリは無効」を検証項目に追加（決定 #11 でタブは無効化の対象から外れることも、暗黙にならないよう明記する） |
| `docs/SPECS_ja.md` 6.4 `pfwd test`（397〜414 行） | console 例に `yq:` 行を追加 |
| `docs/SPECS_ja.md` 10 章 エラーメッセージ方針（523 行付近の表） | 「yq 実装が未対応」の 1 行を追加（`error: unsupported yq implementation: ...`） |
| `docs/SPECS.md` | 上記 4 箇所の英訳 |
| `README_ja.md` 依存コマンド表（26 行）と トラブルシュート表（323 行） | 「Go 実装のもの。同名の Python 実装では動作しない」を削除し、両対応であること・kislyuk/yq では jq も要ること・それぞれの下限バージョンに書き換える。トラブルシュートに `unsupported yq implementation` の行を追加 |
| `README.md` | 上記の英訳（対応箇所） |
| `docs/DESIGN_ja.md` 4.1「yq の呼び出し」（216〜228 行） | クエリ表を本設計「変更点 2」の 5 本に差し替える。**実装ごとの分岐を持たない**方針（決定 #1・#2）と、型名を bash 側で正規化する仕組み（`_yq_kind`）を追記。「設定ファイル 1 つあたり 4 回」の記述が実体（5 回）とずれているので併せて直す |
| `docs/DESIGN_ja.md` 5 章 関数表（361 行付近） | `_yq_kind` / `_yq_is_map` / `_yq_is_null` / `_yq_detect` / `_yq_diagnose` の 5 行を追加 |
| `docs/DESIGN_ja.md` 7.2 依存コマンド検査（849〜852 行） | 「yq のバージョン判定は行わない」は**維持**したうえで、実装判定は `_check_prerequisites` ではなく**解析失敗時にだけ**行うこと、そのとき jq の存在も確認することを追記 |
| `docs/DESIGN_ja.md` 8 章 起動時間（894 行付近） | 正常経路の外部コマンド起動数が**変わらない**こと（判定は失敗時と `pfwd test` のみ）を明記 |
| `docs/DESIGN_ja.md` 9 章 テスト方針（917 行付近） | `yq` スタブによる実装判定テスト、正常時に `--version` が起動しないことの回数検証、kislyuk/yq がある環境でのみ走る任意テストの存在を追記 |
