---
title: config --init の保存先を -c/--config で指定できることを正式化する
created: 2026-09-12
updated: 2026-09-12
status: 実装済み
---

# 要求

```text
pfwd config --init で作成するconfigの保存先を、オプショナルで指定できるようにしたい
```

# 設計: `config --init` の保存先指定の正式化

## 目的

`pfwd config --init` の作成先を、ユーザーが任意のパスに指定できることを **仕様・ヘルプの両方で明示する**。
手段は既に実装済みの共通オプション `-c, --config <PATH>` とし、新しい構文は追加しない。

あわせて、保存先を指定できるようになったことで現実に起きる 3 つの境界条件を潰す。

- 指定先がディレクトリだったとき、`--force` 付きだと `cat > <dir>` の bash エラーが素通りする
- 位置引数（`pfwd config --init ~/foo.yaml`）が黙って無視され、既定パスに作られたことに気づけない
- 既定探索パス以外に作っても `_config_find` はそこを探さないため、次から `-c` が要ることが伝わらない

**変わらないもの**: 既定パス（`~/.config/port-forwarder/config.yaml`）での `config --init` の出力・終了コード・生成されるテンプレート本文は一切変えない。

## 現状（出発点）

### 読んだ既存設計文書

| 文書 | 状態 |
| --- | --- |
| `docs/SPECS_ja.md` | 存在。外部仕様の正典。3.2 共通オプション（`-c, --config <PATH>`）、4.1 配置場所（探索順）、4.5 雛形生成、10 章 エラーメッセージ方針が今回の設計を縛る |
| `docs/SPECS.md` | 上記の英訳。日本語版に従属（`CLAUDE.md`「Handling Documentation」） |
| `docs/DESIGN_ja.md` | 内部設計書。`ARCHITECTURE.md` 相当。5 章の `_cmd_config` 行（`--init` / `--force` / 引数なし）、引数解析の方針、7.3 エラーメッセージ集約が該当 |
| `ARCHITECTURE.md` / `SPECS.md`（リポジトリ直下） | **無い**。`docs/` 配下の上記 3 本がその役割を担う |

`SPECS_ja.md` は `SPEC-xxx` 形式の ID 体系を持たないため、以降は節番号で名指す。

**SPECS 4.5（雛形生成）には保存先を指定する記述が無い。** SPECS 3.2 は `-c` を「使用する設定ファイルを指定する」とだけ書いており、`--init` の作成先になるとは読めない。
つまり今回は「既存仕様の改訂」であり、振る舞いを新規に足す要求ではない。

### 現在の配線

| 場所 | 内容 |
| --- | --- |
| `pfwd:2731` `_parse_args` | `-c/--config <PATH>` と `--config=PATH` を `_OPT_CONFIG` に格納。`--init` / `--force` は値なしオプションとして `_SUBCMD_OPTS` に収集。サブコマンド以降の非オプション引数は `_ARGS` に積まれる |
| `pfwd:2046` `_cmd_config` | `_SUBCMD_OPTS` を走査。`--init` 時は `_OPT_CONFIG` があれば `_expand_tilde` を通した値、無ければ `_config_user_path` を `TARGET` として `_config_init` を呼ぶ。**`_ARGS` は見ていない** |
| `pfwd:869` `_config_init <PATH> <FORCE>` | `[[ -e "$PATH_" && -z "$FORCE" ]]` なら「already exists」で終了コード 1 → `dirname` して `mkdir -p` → heredoc を `cat >` で書き出し → `chmod 600` → `Created:` と `Edit the file and run 'pfwd test' to validate.` の 2 行を出力 |
| `pfwd:462` `_config_user_path` | `$XDG_CONFIG_HOME` があればそれ、無ければ `~/.config` 配下の `port-forwarder/config.yaml` |
| `pfwd:472` `_config_find` | `_OPT_CONFIG` 指定時はそのパス（存在しなければ終了コード 3）。未指定時の候補は `_config_user_path` と `/etc/port-forwarder/config.yaml` の 2 つだけ |
| `pfwd:2813` main dispatch | `config` は `_check_prerequisites` も `_config_setup` も通らず、`_cmd_config` のみを呼ぶ |

**したがって `pfwd -c ~/work/pfwd.yaml config --init` は今日の時点で正しく動く。** 未記載なだけ。

### 既にあって使えるもの

- `_OPT_CONFIG` + `_expand_tilde`（`pfwd:276`）── パス指定の受け口。新設不要
- `_config_user_path`（`pfwd:462`）── 既定パス判定にそのまま使える
- `_error_exit <CODE> <MSG>`（`pfwd:324`） / `_usage <MSG>`（`pfwd:1835`、usage を出して終了コード 2）
- `_err_*` 関数群（`pfwd:432-`）── DESIGN 7.3 のエラーメッセージ集約先
- `_EXIT_*` 定数（数値のハードコード禁止）
- `test/test_config.bats:139-159` ── `--config <PATH> config --init` を使った既存テスト 2 本。既に保存先指定を前提にしている

## 決定

| # | 論点 | 決定 | 理由 |
| --- | --- | --- | --- |
| 1 | 保存先の指定方法 | `-c, --config <PATH>` を正式な手段として文書化・ヘルプ表示する。位置引数 `config --init [PATH]` も `--init=PATH` も追加しない | 既に実装済みで動作しており（`pfwd:2054-2058`）、新構文を足すと `-c` との二重系になる。`--init` を値付きにするとパーサ（DESIGN 引数解析）の値なしオプション一括収集を崩す。**ユーザー確認済み** |
| 2 | `-c` と新指定の競合 | `-c` を優先。#1 により競合ケース自体が発生しない | **ユーザー確認済み**。#1 と整合 |
| 3 | `config` に位置引数が与えられたとき | `_usage` で終了コード 2。メッセージで `-c` の使い方を案内する。`--init` の有無にかかわらず `config` 全体に適用 | 現状は黙って無視され、`pfwd config --init ~/foo.yaml` が既定パスに作成されて気づけない。作成系コマンドで意図と違う場所に書くのは実害が大きい。**ユーザー確認済み** |
| 4 | 指定先が既存ディレクトリのとき | `_error_exit "$_EXIT_ERROR"` で明示エラー。`--force` の判定より前に行う | 現状は `-e` 判定に引っかかり「already exists」（誤解を招く）、`--force` 付きだと `cat > <dir>` が失敗して bash のリダイレクトエラーが素通りする。`<DIR>/config.yaml` への自動補完は行わない。**ユーザー確認済み** |
| 5 | 作成後の案内 | 既定探索パス **以外** に作成したときだけ `Note:` 行を 1 行追加する | `_config_find`（`pfwd:472-489`）は任意パスを探索しないため、作っただけでは使われない。既定パス時に出すと毎回冗長で、既存テストの期待値も壊す。**ユーザー確認済み** |
| 6 | #5 の「既定探索パス」の判定 | `_config_user_path` の値、または `/etc/port-forwarder/config.yaml` と一致するかで判定する | `_config_find` の候補リストと一致させる。ユーザーパスだけで判定すると、root が `/etc/...` に作ったときに不要なヒントが出る |
| 7 | ヘルプの出し方 | `_help_config`（`pfwd:1957`）の usage 行とオプション欄に `-c <PATH>` を明記。`_show_usage` の common options は既に `-c` を載せているので変更しない | `pfwd help config` だけを読む人に届けばよい。全体 usage に重複記載を増やさない |
| 8 | エラーメッセージの置き場所 | `_err_config_is_dir` / `_err_config_no_args` を `_err_*` 節に追加する | DESIGN 7.3「エラーメッセージは `_err_*` に集約」。SPECS 10 章の「何が / なぜ / どうすれば」を満たす文面にする |
| 9 | 既定パス時の出力 | `Created:` と `Edit the file and run 'pfwd test' to validate.` の 2 行を変えない | SPECS 4.5 の console 例と `test/test_config.bats:139-159` を壊さない |

## 変更点

### 1. `pfwd` ─ エラーメッセージ関数の追加（`_err_*` 節, 432 行付近）

```bash
_err_config_is_dir()   { echo "$1 is a directory. Specify the config file itself (e.g. $1/config.yaml)"; }
_err_config_no_args()  { echo "'config' takes no arguments. Use '${__SCRIPT_NAME} --config <PATH> config --init' to choose where the file is created."; }
```

決定 #8。

### 2. `pfwd` ─ `_cmd_config`（2046 行）で位置引数を拒否

オプション走査ループの前に 1 箇所だけ足す。

```bash
(( ${#_ARGS[@]} > 0 )) && _usage "$(_err_config_no_args)"
```

決定 #3。`_usage` が終了コード 2 で抜けるため、以降の分岐は変えない。

### 3. `pfwd` ─ `_config_init`（869 行）にディレクトリ判定を追加

`-e` の既存判定 **より前** に置く（決定 #4）。

```bash
_config_init() {
  local PATH_=$1 FORCE=$2 DIR
  [[ -d "$PATH_" ]] && _error_exit "$_EXIT_ERROR" "$(_err_config_is_dir "$PATH_")"
  if [[ -e "$PATH_" && -z "$FORCE" ]]; then   # 既存のまま
  ...
```

### 4. `pfwd` ─ `_config_init` 末尾に Note 行を追加

決定 #5 / #6。`chmod 600` の後、既存 2 行の出力に続けて条件付きで 1 行。

```bash
  printf 'Created: %s\n' "$PATH_"
  printf "Edit the file and run '%s test' to validate.\n" "$__SCRIPT_NAME"
  if [[ "$PATH_" != "$(_config_user_path)" && "$PATH_" != '/etc/port-forwarder/config.yaml' ]]; then
    printf "Note: this path is not searched automatically. Run '%s --config %s <subcommand>'.\n" \
      "$__SCRIPT_NAME" "$PATH_"
  fi
```

出力例:

```console
$ pfwd config --init
Created: /home/komori/.config/port-forwarder/config.yaml
Edit the file and run 'pfwd test' to validate.

$ pfwd --config ~/work/pfwd.yaml config --init
Created: /home/komori/work/pfwd.yaml
Edit the file and run 'pfwd test' to validate.
Note: this path is not searched automatically. Run 'pfwd --config /home/komori/work/pfwd.yaml <subcommand>'.

$ pfwd config --init ~/work/pfwd.yaml
error: 'config' takes no arguments. Use 'pfwd --config <PATH> config --init' to choose where the file is created.
usage: pfwd <subcommand> [options] [entry...]
...
（終了コード 2）

$ pfwd --config ~/work config --init
error: /home/komori/work is a directory. Specify the config file itself (e.g. /home/komori/work/config.yaml)
（終了コード 1）
```

### 5. `pfwd` ─ `_help_config`（1957 行）

決定 #7。

```text
usage: pfwd [-c <PATH>] config [--init [--force]]

With no option, show the path of the config file in use.

options:
  --init        create a template config file
  --force       overwrite an existing file (with --init)

The file is created at $XDG_CONFIG_HOME/port-forwarder/config.yaml (or
~/.config/port-forwarder/config.yaml). Give -c, --config <PATH> before the
subcommand to create it somewhere else; that path is not searched
automatically, so pass -c again when running pfwd.
```

### 6. `test/test_config.bats` ─ テスト追加（コメントは日本語）

- `config --init` に位置引数を渡すと終了コード 2 とエラーメッセージ（決定 #3）
- 引数なしの `config` に位置引数を渡しても終了コード 2（決定 #3 の適用範囲）
- 保存先がディレクトリなら終了コード 1 と `is a directory`。`--force` 付きでも同じ（決定 #4）
- 既定外パスに作ると `Note:` 行が出る（決定 #5）
- `XDG_CONFIG_HOME` を `BATS_TEST_TMPDIR` に向けて既定パスに作ると `Note:` 行が出ない（決定 #5 の裏側）

## 触らないもの

| 触らないもの | 理由 |
| --- | --- |
| `_config_find` の探索順と `conf.d` マージ（SPECS 4.1） | 作成先の話であり、読み込み先の仕様は変えない。触ると既存ユーザーの設定解決が変わる |
| `-c, --config` のグローバルな意味 | 他サブコマンドでは「読む設定ファイル」のまま。`config --init` でだけ「書く先」になるのは既存挙動 |
| `PFWD_CONFIG` のような環境変数の新設 | 要求に無い。設定解決の経路が増えると SPECS 4.1 の探索順を書き直すことになる |
| テンプレート本文（heredoc） | 保存先の話と無関係 |
| `_parse_args` の値なしオプション一括収集 | 決定 #1 により `--init` を値付きにする必要が無い |
| `install.sh` | bash 3.2 制約下の別系統。今回の変更と無関係 |

## 実装手順

小規模（`pfwd` 1 ファイル + テスト）のためフェーズ分割はしない。上から順に実施する。

1. `_err_config_is_dir` / `_err_config_no_args` を追加（変更点 1）
2. `_cmd_config` に位置引数チェックを追加（変更点 2）
3. `_config_init` にディレクトリ判定を追加（変更点 3）
4. `_config_init` に Note 行を追加（変更点 4）
5. `_help_config` を更新（変更点 5）
6. テストを追加（変更点 6）
7. `bash -n pfwd` と `shellcheck -x -s bash pfwd install.sh` を 0 件で通す
8. `bats test/` 全通過を確認

## 検証

### 自動

| 対象 | 確認すること |
| --- | --- |
| `test/test_config.bats:139`（既存） | `--config <PATH> config --init` の成功・二重生成エラー（1）・`--force` 成功が**従来どおり**。出力の `Created:` 行も従来どおり |
| `test/test_config.bats:152`（既存） | 生成した雛形が `list` で読めることが**変わらない** |
| 追加テスト | 位置引数 → 終了コード 2 / ディレクトリ → 終了コード 1 / 既定外パス → `Note:` 行あり / 既定パス → `Note:` 行**なし** |
| `bats test/` 全体 | 他のテストが 1 本も落ちないこと（`config` 以外の経路に手を入れていないことの確認） |
| `shellcheck -x -s bash pfwd install.sh` | 0 件（suppress を増やさない） |

### 手動

1. `TMP=$(mktemp -d); XDG_CONFIG_HOME="$TMP/cfg" ./pfwd config --init` → `Created: $TMP/cfg/port-forwarder/config.yaml` と `Edit the file...` の **2 行だけ**（`Note:` が出ないこと）
2. `./pfwd --config "$TMP/work/pfwd.yaml" config --init` → 2 行 + `Note:` 行。`ls -l "$TMP/work/pfwd.yaml"` が `-rw-------`
3. `./pfwd config --init "$TMP/x.yaml"` → `error: 'config' takes no arguments...` + usage、`echo $?` が 2。**`$TMP/x.yaml` も既定パスのファイルも作られていない**こと
4. `./pfwd config "$TMP/x.yaml"` → 同じく終了コード 2
5. `./pfwd --config "$TMP/work" config --init` → `error: ... is a directory ...`、`echo $?` が 1
6. `./pfwd --config "$TMP/work" config --init --force` → 同じエラーで終了コード 1（bash のリダイレクトエラーが出ないこと）
7. `./pfwd --config "$TMP/work/pfwd.yaml" list` → 生成した雛形の `example` が表示される
8. `./pfwd help config` に `-c, --config <PATH>` の説明が出る

### 見えないものの確認

- 手順 3 で、既定パス（`$XDG_CONFIG_HOME/port-forwarder/config.yaml`）に**ファイルが作られていない**こと
- 手順 1 の出力に `Note:` の文字列が**含まれない**こと

## 見送った案

| 案 | 見送った理由 |
| --- | --- |
| 位置引数 `pfwd config --init [PATH]` | ユーザーが `-c` の文書化のみを選択。`-c` と二重の指定経路ができ、競合時の優先順位という余計な仕様を抱える |
| `--init=PATH` / `--init PATH`（値付きオプション） | `_parse_args` の値なしオプション一括収集（DESIGN 引数解析）から `--init` を外す必要があり、`--init --force` との区切り判定が増える。得られるものは位置引数案と同じ |
| ディレクトリ指定時に `<DIR>/config.yaml` へ補完 | 「パスを指定したのに別名のファイルができる」暗黙の変換になる。明示エラーで案内する方が誤りに気づける（決定 #4） |
| `Note:` 行を常に出す | 既定パス利用者（大多数）に毎回無意味な 1 行が出る。SPECS 4.5 の console 例と既存テストの期待値も書き換えになる |
| 余分な位置引数を警告して続行 | 作成系コマンドで意図と違う場所に書いてしまう事故を止められない（決定 #3） |
| `PFWD_CONFIG` 環境変数の導入 | 要求の範囲外。設定解決経路が増え SPECS 4.1 の全面改訂になる |
| 位置引数を現状どおり黙って無視 | `pfwd config --init ~/foo.yaml` が既定パスに作成される事故がそのまま残る |
| 設計書を `docs/` 直下に置く | `docs/` は SPECS / DESIGN の常設文書の並び。機能単位の設計書を混ぜると並びが壊れるため `docs/design/` を新設した。ファイル名の `_ja` は本リポジトリの「日本語が正典」規約に合わせたもの |

## 実装後に更新する文書

**この設計の時点では反映しない。** 日本語版を先に更新し、その後で英訳に反映する（`CLAUDE.md`「Handling Documentation」）。

| 文書 | 追記する内容 |
| --- | --- |
| `docs/SPECS_ja.md` 4.5 雛形生成 | 既存 console 例の後に、`-c <PATH>` で作成先を指定できること、その場合 `Note:` 行が出ること、作成先がディレクトリならエラー（終了コード 1）、`config` は位置引数を取らない（終了コード 2）ことを追記 |
| `docs/SPECS_ja.md` 3.2 共通オプション | `-c, --config <PATH>` の説明に「`config --init` では雛形の作成先になる」を追記 |
| `docs/SPECS_ja.md` 10 章 エラーメッセージ方針（表） | 「設定ファイル作成先がディレクトリ」「`config` に余分な引数」の 2 行を追加 |
| `docs/SPECS.md` | 上記 3 箇所の英訳（4.5 / 3.2 / 10 章） |
| `README_ja.md` クイックスタート 1.（101 行付近）とサブコマンド表（252 行） | 任意の場所に作る例を 1 つ追加し、表の `config` 行に `-c` で作成先を指定できる旨を添える |
| `README.md` | 上記の英訳（102 行 / 253 行） |
| `docs/DESIGN_ja.md` 5 章 `_cmd_config` 行（669 行） | 「位置引数を受け付けない（終了コード 2）」「作成先の決定と既定外パス時の案内」を追記 |
| `docs/DESIGN_ja.md` 7.3 エラーメッセージ一覧（859 行付近） | `_err_config_is_dir` / `_err_config_no_args` の 2 行を追加 |
