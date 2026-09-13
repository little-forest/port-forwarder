# port-forwarder 内部設計書

本書は [SPECS_ja.md](SPECS_ja.md)（外部設計書）で定義された振る舞いを、**どのように実装するか**に絞って定義する。
ユーザーから見た仕様（CLI・設定ファイル・出力・終了コード）は SPECS_ja.md を正とし、本書では重複記載を最小限にする。

- 対象バージョン: v1.0（初版）
- 作成日: 2026-09-08
- 状態: 実装済み（2026-09-08）
- 実装言語: bash（コーディング作法は 2 章に定める）

---

## 1. 設計方針

### 1.1 確定した設計判断

| 項目 | 決定 | 理由 |
| --- | --- | --- |
| 成果物構成 | `pfwd` **単一ファイル**にすべての機能を実装する | 配布が 1 ファイルのコピーで済む。共通関数群（`__` 始まり）も同一ファイルに内包し、外部ファイルへの依存を持たない |
| bash バージョン | **bash 4.2 以上を必須**とする | 連想配列を設定・状態の保持に用いる。3.2 互換のために区切り文字付き配列で代替すると、設定マージと状態機械の実装が著しく複雑になる |
| デーモン方式 | **単一プロセスによる集中管理ループ** | プロセス数が `デーモン 1 + ssh N` に収まり、SPECS 11 章のリソース要件を満たしやすい。停止処理も 1 箇所に閉じる |
| CLI → デーモン制御 | **希望状態ファイル（desired）の書き換え + SIGUSR1** | 命令の取りこぼし・重複がなく、SPECS 11 章の冪等性要件（`start` / `stop` は状態に関わらず同じ結果に収束）と構造的に一致する |
| SSH セッション制御 | **ControlMaster 併用**（`-M -S <ControlPath>`、`-O check` / `-O exit`）。PID による kill をフォールバックに持つ | SPECS 8.1 の ControlPath 記載と整合。`process` チェックの精度が上がり、停止時に確実に終了させられる |
| デーモン未起動時の `start` | **エラー終了（終了コード 5）** し `pfwd up` を案内する | SPECS 7 章の終了コード 5 と整合。監視外のセッションを作らず、状態管理系統を 1 つに保つ |
| テスト | **bats-core** による自動テスト | 設定パース・検証・状態遷移は副作用なしで検証できるため、関数分割の段階からテスト可能性を設計に織り込む |

### 1.2 SPECS_ja.md への反映が必要な差分

実装方針の確定に伴い、SPECS_ja.md 側に以下の修正・追記が必要となる。**本書では下記を確定仕様として扱う**。

| # | SPECS 該当箇所 | 現行記述 | 本設計での扱い |
| --- | --- | --- | --- |
| 1 | 2.1 依存コマンド | 「bash 3.2 でも動作するよう配慮する」 | **bash 4.2 以上を必須**とする。起動時にバージョンを判定し、満たさなければ終了コード 7 で終了する。下限が 4.0 でなく 4.2 なのは、グローバル宣言に `declare -g` を使うため（bats はテストファイルを関数内で source するため、`declare -A` だけでは連想配列が局所変数になり 10 章のテスト方針が成立しない） |
| 2 | 6.3 `start` | デーモンの要否に言及なし | `start` / `stop` / `restart` / `reload` は**デーモン起動中であることが前提**。未起動時は終了コード 5 |
| 3 | 4.3 global | 監視の接続タイムアウトが未定義 | 死活監視の TCP プローブ用に内部定数 `_CHECK_TIMEOUT`（3 秒）と `_REMOTE_PROBE_WAIT`（1.0 秒）を持つ。将来 `global.check_timeout` として公開する余地を残す |
| 4 | 4.2 設定例 | `ExitOnForwardFailure` をエントリの `ssh_options` で明示 | **既定で常に付与**する。ユーザー指定の `ssh_options` は既定値の後に並べ、上書き可能とする |
| 5 | 7 章 | `--exit-code` が 7 章にのみ登場 | `status` サブコマンド固有のオプションとして扱う（3.2 の共通オプションではない） |
| 6 | 8.1 実行時状態 | `${XDG_RUNTIME_DIR:-~/.local/state/port-forwarder/run}/port-forwarder/` | `XDG_RUNTIME_DIR` 未設定時は `~/.local/state/port-forwarder/run/` を実行時ディレクトリとする（`port-forwarder` を二重に付けない）。3.3 節参照 |

---

## 2. コーディング規約

本章が本スクリプトのコーディング規約の唯一の正であり、外部のテンプレートやライブラリを参照しない。

### 2.1 基本規約

| 項目 | 規約 |
| --- | --- |
| ヘッダ | 先頭に下記のコメントブロック（ファイル名・一行説明・開始日・Copyright）を置く |
| 折り畳み | 関数・ブロックは `#{{{` … `#}}}` で囲む。末尾に `# vim: ts=2 sw=2 sts=2 et nu foldmethod=marker` を置く |
| インデント | スペース 2、タブ不使用 |
| 共通関数 | `__` で始まる汎用基盤関数（下記一覧）。用途を限定し、スクリプト固有のロジックを持ち込まない |
| 固有関数 | `_` で始まる（`_config_load`、`_cmd_status` など） |
| グローバル変数 | `_` + 大文字スネークケース（`_CONFIG_FILE`、`_RUN_DIR`）。共通基盤由来は `__` + 大文字（`__SCRIPT_NAME`、`__SILENT`） |
| ローカル変数 | 関数内で必ず `local` 宣言し、大文字スネークケース |
| 色 | `__setup_color` で定義される `C_GREEN` / `C_YELLOW` / `C_RED` / `C_GREY` / `C_OFF` を使う。非 TTY・`--no-color` 時は `__setup_color` を呼ばず、変数が空文字のまま無害に展開されることを利用する |
| 終了処理 | `__script_end_*` という名前の関数を定義すると `trap EXIT` から自動実行される仕組みを利用する |
| 一時ファイル | ベースパスはファイルスコープの `__TMP_BASE` 1 か所で確定する。`__make_tmp` がそれを遅延生成して一時ファイルを作り、終了時に `__script_end_clean_tmp` が**同じ変数を見て**削除する |
| 静的検査 | shellcheck を通す。抑止は必要最小限とし、必ず理由をコメントで添える |

#### ヘッダ書式

```bash
#!/usr/bin/env bash
#===============================================================================
# <スクリプト名> : <一行説明>
# Date    :  <YYYY-MM-DD> Start
# Copyright: Original code by Yusuke Komori.
#                       Copyright (c) <YYYY>. Yusuke Komori, All rights reserved.
#===============================================================================
```

#### 共通基盤関数（`__` 始まり）

| 関数 | 役割 |
| --- | --- |
| `__setup` | 起動直後の初期化。標準出力が TTY でなければ `__SILENT` を立てる |
| `__setup_color` | `C_GREEN` / `C_YELLOW` / `C_RED` / `C_GREY` / `C_OFF` を ANSI SGR シーケンスで定義する（`tput` は使わない） |
| `__show_info` / `__show_warn` / `__show_error` | ユーザー向けメッセージ出力。`__show_error` のみ stderr に出す |
| `__error_end` | `__show_error` を出して終了する |
| `__script_end` | `trap EXIT` から呼ばれ、`__script_end_*` という名前の関数をすべて名前順に実行する |
| `__get_tmp_base` | `__TMP_BASE` を返すアクセサ（共有ボイラープレートとの互換のために残している） |
| `__make_tmp` | ベースディレクトリ（`__TMP_BASE`）を遅延生成し、その中に一時ファイルを作る。生成に失敗したら 1 を返す |
| `__script_end_clean_tmp` | 終了時に `__TMP_BASE` を削除する（`__script_end` から自動実行される） |

### 2.2 本スクリプトで追加する規約

| 項目 | 規約 |
| --- | --- |
| `set -e` / `set -u` | **使わない**。デーモンのループや死活監視は「失敗しうる処理を続行しながら状態に反映する」構造であり、途中終了されると状態機械が壊れるため。異常系は関数の戻り値で表現し、呼び出し側で必ず判定する |
| 戻り値 | 「成功 = 0 / 失敗 = 1 以上」を守る。真偽を返す関数は `_is_*` / `_has_*` の名前にする |
| 標準出力の用途 | 値を返す関数は結果のみを stdout に出す。ユーザー向けメッセージは `__show_*` / `_show_result`、ログは `_log` を通す（混在させない） |
| 外部コマンド起動 | デーモンのループ内では極力避ける。bash 組み込み（`printf '%(%s)T'`、`/dev/tcp`、`[[ ]]`）を優先する |
| 変数展開 | 変数は必ずクォートする。配列は `"${ARR[@]}"` で展開する |
| ssh 引数 | 文字列連結ではなく**配列**（`_SSH_ARGS`）に積んで展開する。ホスト名・パスに空白が含まれても壊れないようにする |
| エラーメッセージ | SPECS 10 章の方針（何が / なぜ / どうすれば）に従い、メッセージ定義は `_err_*` 関数に集約する |

### 2.3 結果表示ヘルパ

エントリ単位の成否表示は、SPECS 6.3 / 6.4 の `[  OK  ]`（6 文字幅）表記に合わせ、次のヘルパに一本化する。

```
_show_result <RESULT> <NAME> <MESSAGE>
  RESULT: OK | FAILED | WARN | SKIP
  出力  : "[  OK  ] db-prod    connected (127.0.0.1:15432 -> db.internal:5432)"
  色    : OK=緑 / WARN=黄 / FAILED=赤 / SKIP=灰
  NAME 欄は _NAME_WIDTH（全対象エントリ名の最大長、最小 10）で左詰めパディングする
```

`--quiet` 指定時は `_show_result` と `__show_info` を抑止し、`__show_error` のみ出力する。

---

## 3. ファイル構成と実行時レイアウト

### 3.1 スクリプト内のセクション構成

`pfwd` 単一ファイルを、以下の順序のセクションで構成する。各セクションは `#{{{` … `#}}}` で折り畳む。

```
 1. ヘッダコメント                       2.1 のヘッダ書式（ファイル名・日付・Copyright）
 2. common global variables              __SCRIPT_BASE / __SCRIPT_NAME / __TMP_BASE / __SILENT
 3. global variables                     _VERSION / _CONFIG_FILE / _RUN_DIR / 連想配列群 / 終了コード定数
 4. common functions                     __ 始まりの共通基盤関数（__setup, __setup_color, __show_*, __make_tmp ...）
 5. utility functions                    _now / _epoch_to_hms / _expand_tilde / _in_array
 6. logging functions                    _log_init / _log / _debug
 7. config functions                     _config_find / _config_load / _config_validate ...
 8. state functions                      _state_* / _desired_*
 9. ssh session functions                _ssh_* / _ctl_path
10. health check functions               _probe_* / _health_check / _is_port_free
11. daemon functions                     _daemon_* / シグナルハンドラ
12. subcommand functions                 _cmd_*
13. usage / help                         _usage / _help_<subcommand>
14. main process                         引数解析 → 前提チェック → サブコマンドディスパッチ
15. vim modeline
```

セクション 14 の直前に、**bats からの読み込み用ガード**を置く。

```bash
# テスト時は関数定義のみ読み込む
[[ -n "$PFWD_SOURCE_ONLY" ]] && return 0
```

### 3.2 配布物

| ファイル | 内容 |
| --- | --- |
| `pfwd` | 本体（実行可能） |
| `README_ja.md` / `README.md` | 利用者向け README（日本語版が正、英語版は翻訳） |
| `docs/SPECS_ja.md` / `docs/SPECS.md` | 外部設計（日本語版が正、英語版は翻訳） |
| `docs/DESIGN_ja.md` | 内部設計（本書。英語版は未作成） |
| `test/*.bats` / `test/helper.bash` | bats テスト |
| `test/fixtures/*.yaml` | テスト用設定ファイル |
| `aqua.yaml` | テストツールチェーンの定義（aqua） |

`__SCRIPT_NAME` は usage・メッセージの表示にのみ使う。

### 3.3 実行時ディレクトリ

起動時に実行モードを判定し、`_RUN_DIR` を決定する。

| モード | 判定 | `_RUN_DIR` |
| --- | --- | --- |
| ユーザー | 既定 | `${XDG_RUNTIME_DIR}/port-forwarder`（`XDG_RUNTIME_DIR` 未設定時は `~/.local/state/port-forwarder/run`） |
| システム | 実効 UID が 0、かつ `/etc/port-forwarder/config.yaml` を採用した場合 | Linux: `/run/port-forwarder` / macOS: `/usr/local/var/run/port-forwarder` |

構成:

```
$_RUN_DIR/
├── daemon.pid            デーモンの PID（1 行）
├── daemon.lock/          ロックディレクトリ（mkdir の原子性を利用）
│   └── pid               ロック保持者の PID
├── daemon.meta           デーモンが採用した設定ファイルパス・起動時刻
├── state/
│   ├── <name>.state      エントリ状態（書き手はデーモンのみ）
│   └── <name>.desired    希望状態（書き手は CLI のみ）
├── ctl/
│   └── <name>.sock       SSH ControlPath
└── err/
    └── <name>.err        直近の ssh の標準エラー出力
```

パーミッションは `_RUN_DIR` を `0700`、配下のファイルを `0600` とする（`umask 077` を起動直後に設定する）。

#### ControlPath の長さ対策

UNIX ドメインソケットのパス長上限は macOS で 104、Linux で 108 バイト。`_RUN_DIR` が深い場合やエントリ名が長い場合に上限を超えうる。`_ctl_path <name>` は次のように決定する。

1. 既定は `$_RUN_DIR/ctl/<name>.sock`
2. 長さが 100 バイトを超える場合は `${TMPDIR:-/tmp}/pfwd-$(id -u)/<name の cksum 値>.sock` を使う
3. それでも超える場合は当該エントリを `failed` とし、理由をログに記録する

決定した ControlPath は state ファイルの `ctl` に記録し、CLI 側は再計算せず state から読む。

---

## 4. データモデル

### 4.1 設定の内部表現

bash 4 の連想配列に平坦化して保持する。キーは `<エントリ名>.<設定キー>`。

| 変数 | 型 | 内容 |
| --- | --- | --- |
| `_CFG_NAMES` | 配列 | エントリ名（YAML 記述順、マージ後） |
| `_CFG` | 連想配列 | `_CFG["db-prod.host"]="bastion.example.com"` |
| `_CFG_OPTS` | 連想配列 | `ssh_options` を `\x1f` 区切りで連結した文字列 |
| `_GLOBAL` | 連想配列 | `_GLOBAL["check_interval"]=30` |
| `_CFG_INVALID` | 連想配列 | 検証に失敗したエントリ名 → 理由文字列 |
| `_CFG_SOURCE` | 連想配列 | エントリ名 → 定義元ファイルパス（エラーメッセージ用） |

`ssh_options` に `\x1f` を含む指定は検証エラーとする。

#### yq の呼び出し

**設定ファイル 1 つあたり 5 回**の `yq` 呼び出しで全情報を取得する。エントリごとの呼び出しは行わない（SPECS 11 章の起動時間要件のため）。

`yq` は mikefarah/yq（Go 実装）と kislyuk/yq（Python 実装。jq のラッパー）の両方に対応するが、
**クエリ文字列は 1 本しか持たず、実装による分岐も前置きも行わない**。これを成立させるための約束が 2 つある。

- 型の取得には両実装が共通して持つ **`type`** を使う（`tag` は jq に無い）。
- クエリ内に型名の文字列（`"!!map"` / `"object"`）を**書かない**。型の判定は
  `select((.value | type) == ({} | type))` のように**リテラルの型と比較**する。こうすると戻り値の
  表記が実装ごとに違っても式の意味が変わらない。
- 後置の `to_entries[]` は mikefarah v4.35 以前で構文エラーになるため、**`to_entries | .[]`** と書く。

`<US>` は 0x1f（`_US`）のリテラル 1 バイト。区切りに `@tsv` を使わないのは、タブ・改行・null の
扱いが実装ごとに食い違うため（`join` ならどちらも生のまま通す）。

| # | 目的 | クエリ |
| --- | --- | --- |
| 0 | 構造検証 | `.entries \| type` → `map` / `null` 以外は終了コード 3 |
| 1 | エントリ名（記述順）と値の型 | `(.entries // {}) \| to_entries \| .[] \| [.key, (.value \| type)] \| join("<US>")` |
| 2 | global | `(.global // {}) \| to_entries \| .[] \| select((.value\|type) != ([]\|type) and (.value\|type) != ({}\|type)) \| [.key, .value] \| join("<US>")` |
| 3 | エントリのスカラー値 | `(.entries // {}) \| to_entries \| .[] \| select((.value\|type) == ({}\|type)) \| .key as $n \| .value \| to_entries \| .[] \| select((.value\|type) != ([]\|type) and (.value\|type) != ({}\|type)) \| [$n, .key, .value] \| join("<US>")` |
| 4 | `ssh_options`（配列） | `(.entries // {}) \| to_entries \| .[] \| select((.value\|type) == ({}\|type)) \| select(((.value.ssh_options // []) \| type) == ([]\|type)) \| select(((.value.ssh_options // []) \| length) > 0) \| .key as $n \| (.value.ssh_options // []) \| .[] \| [$n, .] \| join("<US>")` |

- クエリ 0 の終了コードが 0 以外なら、`_yq_diagnose` で yq 側に原因があるかを切り分けたうえで
  （7.2）、stderr をそのままユーザーに提示して終了コード 3。
- `type` の戻り値は実装ごとに表記が違う（mikefarah は `!!map` などの YAML タグ、kislyuk は
  `object` などの jq 型名）。**bash 側の `_yq_kind` で `map` / `seq` / `str` / `number` / `bool` /
  `null` に正規化**してから表示・分岐に使う。空出力も `null` とみなす（空ファイルの吸収を兼ねる）。
  ループ内で `$( )` を起こさないよう、分岐には述語 `_yq_is_map` / `_yq_is_null` を使う。
- 読み込みは `while IFS=$_US read -r ...` で行い、パイプによるサブシェル化を避けるためプロセス置換
  （`done < <(...)`）を使う。
- 区切りの数が想定と違う行は、**多い → 値に 0x1f が入っている / 少ない → 直前の値が複数行**、と
  切り分けて該当エントリを検証エラーにする。継続行の文字列をエントリ名と取り違えないよう、直前の
  エントリ名・キー名をループ内で持ち回す。
- 値のタブは列をずらさないので、**タブを含む値は許容する**（SPECS 4.4）。

#### マージ規則の実装（SPECS 4.1）

対象ファイルを「メイン設定 → `conf.d/*.yaml|yml` を名前順」で並べ、順に処理する。

- **global**: 読み込んだキーを `_GLOBAL` に代入するだけで自然に後勝ちになる。
- **entries**: ファイル境界でエントリ単位の置換とする。あるファイルで既出のエントリ名が再定義された場合、**そのエントリの既存キーを `_CFG` から全削除してから**新しい値を代入する（キー単位のマージにしない）。
- `_CFG_NAMES` へは初出時のみ追加する（表示順は初出順を維持する）。

この方式は yq のマージ演算子の深さ制御に依存しないため、SPECS 4.1 の規則をそのまま表現できる。

### 4.2 既定値の適用

`_config_apply_defaults` で、未設定のエントリキーに SPECS 4.3 の既定値を埋める。以後のコードは「値は必ず存在する」前提で書ける。

| キー | 既定値 |
| --- | --- |
| `user` | `$USER`（未設定なら空 = ssh に `-l` を渡さず `~/.ssh/config` に委ねる） |
| `port` | `22` |
| `remote_host` | `localhost` |
| `bind_address` | `127.0.0.1` |
| `enabled` | `true` |
| `check_mode` | `remote` |
| `check_interval` | `_GLOBAL[check_interval]` |

global の既定値は SPECS 4.3 の表に従う（`check_interval=30`、`connect_timeout=10`、`retry_initial=5`、`retry_max=300`、`retry_limit=0`、`server_alive_interval=15`、`server_alive_count_max=3`）。`check_interval` は最小 5 に丸め、下回る指定は警告を出す。

### 4.3 検証（SPECS 4.4）

`_config_validate` は 2 段階で行う。

**設定全体のエラー（終了コード 3、即終了）**

- YAML の構文解析失敗（yq の終了コードが非 0）
- `.entries` が map でない / 存在しない
- マージ後の `_CFG_NAMES` が空

**エントリ単位のエラー（当該エントリのみ無効化して継続）**

| 検証 | 実装 |
| --- | --- |
| エントリ名 | `[[ $NAME =~ ^[A-Za-z0-9._-]{1,32}$ ]]` |
| 必須キー | `host` / `local_port` / `remote_port` の非空判定 |
| ポート範囲 | `[[ $V =~ ^[0-9]+$ ]] && (( V >= 1 && V <= 65535 ))` |
| `local_port` 重複 | `_SEEN_PORT[<bind_address>:<local_port>]` に登録しながら検出。重複時は**両方**を無効化し、SPECS 10 章の書式でエラー表示 |
| `identity` の存在 | `-f` 判定。存在しなければ無効化 |
| `identity` の権限 | 他ユーザーに読み取り権がある場合はエラー（SPECS 10 章の書式）。`ls -l` の文字列ではなく、`stat` の差異を避けるため `[[ -r ]]` と `find -perm` ではなく、ポータブルに `ls -ln` の 1 列目をパースする |
| `check_mode` | `process` / `tcp` / `remote` のいずれか |
| `enabled` | `true` / `false` / `yes` / `no` / `1` / `0` を受理し真偽に正規化 |
| 未知キー | 既知キー集合 `_KNOWN_ENTRY_KEYS` に無いキーは警告のみ（無効化しない） |
| `bind_address` | `0.0.0.0` または `::` の場合は警告（SPECS 11 章の安全性要件） |

無効化されたエントリは `_CFG_INVALID[name]` に理由を持ち、`status` では `failed`、`test` では `[FAILED]` として表示する。

### 4.4 状態ファイル

`state/<name>.state` は `key=value` の 1 行 1 項目。**`source` はせず**、`while IFS='=' read -r K V` で自前パースする。

| キー | 型 | 意味 |
| --- | --- | --- |
| `status` | 文字列 | `connected` / `connecting` / `retrying` / `stopped` / `disabled` / `failed` |
| `pid` | 整数 | ssh プロセスの PID（無ければ 0） |
| `ctl` | パス | 決定した ControlPath |
| `since` | epoch | 現在の status になった時刻 |
| `connected_since` | epoch | 直近に `connected` になった時刻（UPTIME 表示・バックオフリセット判定に使用） |
| `retry_count` | 整数 | 連続失敗回数 |
| `backoff` | 整数(秒) | 次回の待機秒数 |
| `next_retry_at` | epoch | 次回試行時刻 |
| `next_check_at` | epoch | 次回死活監視時刻 |
| `conn_sig` | 文字列 | 接続パラメータの署名（4.6 節） |
| `last_error` | 文字列 | 直近のエラー要約（改行・タブは除去、256 バイトで打ち切り） |

書き込みは `err/<name>.state.tmp` へ書いてから `mv` でアトミックに置き換える。

### 4.5 希望状態ファイル

`state/<name>.desired` は `up` または `down` の 1 語のみを持つ。

- **書き手は CLI のみ**（`start` / `stop` / `restart`）。デーモンは読むだけ。
- **読み手はデーモンのみ**。
- 書き手と読み手が分離するため、ロックは不要（`mv` によるアトミック置換のみで十分）。
- ファイルが存在しない場合、デーモンは設定の `enabled` を初期値として扱う。
- `reload` で `enabled: false` に変更されたエントリは、デーモンが desired ファイルを削除して `disabled` に落とす（この 1 箇所のみデーモンが desired を消すが、CLI との競合は SIGUSR1 の処理順で解決する。5.7 節参照）。

### 4.6 接続パラメータ署名（`conn_sig`）

`reload` の差分判定（SPECS 5.5）に用いる。ハッシュ化せず、次の値を `\x1f` で連結した文字列をそのまま保持・比較する（外部コマンド不要で、衝突もない）。

```
host / user / port / identity / local_port / remote_host / remote_port / bind_address / ssh_options
```

`description` / `enabled` / `check_mode` / `check_interval` は含めない。したがって、これらのみの変更ではセッションを維持したまま表示・挙動が更新される。

---

## 5. モジュール設計

### 5.1 ユーティリティ

| 関数 | 引数 | 戻り | 説明 |
| --- | --- | --- | --- |
| `_now` | - | stdout: epoch | `printf '%(%s)T' -1`（bash 4.2+）を使い、使えなければ `date +%s` にフォールバック。判定結果は `_HAVE_PRINTF_TIME` にキャッシュする |
| `_timestamp` | - | stdout | ログ用 `%Y-%m-%dT%H:%M:%S%z` |
| `_fmt_uptime` | 秒数 | stdout | `2d 04:11` / `05:22` 形式に整形（SPECS 6.1） |
| `_expand_tilde` | パス | stdout | 先頭 `~` を `$HOME` に展開 |
| `_in_array` | 値 配列要素... | 0/1 | 存在判定 |
| `_truncate` | 文字列 幅 | stdout | 幅超過時に末尾を `...` に置換（SPECS 6.2 の SSH 列） |
| `_sanitize` | 文字列 | stdout | 改行・タブ・制御文字を空白に置換（state / ログ書き込み前に必ず通す） |

### 5.2 ログ

| 関数 | 説明 |
| --- | --- |
| `_log_init` | `log_file` を決定（未指定なら stdout）。指定時は親ディレクトリを作成し、追記可能か検証する。不可なら警告して stdout にフォールバックする |
| `_log <LEVEL> <ENTRY> <MSG...>` | `2026-09-08T21:31:04+0900 [INFO ] [db-prod] message` を 1 行で出力。`ENTRY` に `-` を渡すとエントリ欄を省略する。`LEVEL` は 5 桁左詰め |
| `_log_info` / `_log_warn` / `_log_error` | `_log` のラッパ |
| `_debug <MSG...>` / `_debug2 <MSG...>` | `-v` / `-vv` 指定時のみ **stderr** に出力（SPECS 3.2）。ログファイルには書かない |

- 書き込みは `printf '%s\n' "$LINE" >> "$_LOG_FILE"` の追記のみ。1 行は PIPE_BUF 未満に収まるため、デーモンと CLI が同時に書いても行が壊れない。
- ローテートは行わない（SPECS 6.5）。
- 秘匿情報の混入防止として、ログに出す前に必ず `_sanitize` を通す。ssh の stderr を転記する際も同様。

### 5.3 設定

| 関数 | 説明 |
| --- | --- |
| `_config_find` | `--config` → `$XDG_CONFIG_HOME/port-forwarder/config.yaml` → `~/.config/...` → `/etc/port-forwarder/config.yaml` の順で探索し `_CONFIG_FILE` を決定。見つからなければ終了コード 3 |
| `_config_file_list` | メイン設定 + 同階層 `conf.d/*.yaml`・`*.yml` を名前順で並べた配列 `_CONFIG_FILES` を作る |
| `_config_load` | `_CONFIG_FILES` を順に `_config_parse_file` に渡し、4.1 節のマージ規則で `_CFG` を構築する |
| `_config_parse_file <path>` | 4.1 節の yq クエリ 0〜4 を実行し、0x1f 区切りの行を読み込む |
| `_yq_kind <type 出力>` | `type` の戻り値を `map` / `seq` / `str` / `number` / `bool` / `null` に正規化する。空出力は `null` |
| `_yq_is_map <type 出力>` | マップなら真。ループ内で `$( )` を避けるための述語 |
| `_yq_is_null <type 出力>` | null または空出力なら真 |
| `_yq_detect` | `yq --version` から実装（`go` / `python` / `unknown`）と表示用バージョンを `_YQ_IMPL` / `_YQ_VERSION` に入れる。冪等で、**終了はしない** |
| `_yq_diagnose` | クエリが失敗したときにだけ呼ぶ。Python 実装で `jq` が無ければ `_EXIT_DEPS`、未知の実装なら `_EXIT_DEPS`。それ以外は 0 を返し、呼び出し元が終了コード 3 で終了する |
| `_config_apply_defaults` | 4.2 節 |
| `_config_validate` | 4.3 節 |
| `_config_check_perms` | 設定ファイルが他ユーザーから書き込み可能なら警告（SPECS 11 章） |
| `_config_init <path>` | 雛形生成（SPECS 4.5）。heredoc でコメント付きテンプレートを書き出す。既存時は `--force` が無ければエラー |

### 5.4 状態

| 関数 | 説明 |
| --- | --- |
| `_state_init` | `_RUN_DIR` 配下のディレクトリを `umask 077` で作成 |
| `_state_load <name>` | state ファイルを読み `_ST["<name>.<key>"]` に展開。無ければ既定値で初期化 |
| `_state_load_all` | 全エントリ分を読む（`status` / デーモン起動時） |
| `_state_flush <name>` | `_ST` の内容を state ファイルへアトミック書き込み。**デーモンのみが呼ぶ** |
| `_state_set <name> <key> <value>` | `_ST` を更新し、`_ST_DIRTY[<name>]=1` を立てる（サイクル末尾でまとめて flush） |
| `_state_get <name> <key>` | stdout に値 |
| `_state_transit <name> <new_status> [理由]` | `status` と `since` を更新し、遷移をログに記録する。**状態遷移はすべてこの関数を通す**（ログの一貫性を担保するため） |
| `_state_remove <name>` | state / desired / err ファイルを削除（エントリ削除時） |
| `_desired_set <name> <up\|down>` | CLI が呼ぶ。tmp + `mv` |
| `_desired_get <name>` | 無ければ `enabled` に基づく既定を返す |

デーモン内では `_ST` 連想配列がマスタで、ファイルは CLI に見せるための射影である。ファイル I/O は「変更のあったエントリのみ、サイクル末尾で 1 回」に限定する。

### 5.5 SSH セッション制御

| 関数 | 説明 |
| --- | --- |
| `_ctl_path <name>` | 3.3 節の規則で ControlPath を決定 |
| `_ssh_build_args <name>` | グローバル配列 `_SSH_ARGS` を組み立てる |
| `_ssh_start <name>` | `_SSH_ARGS` で ssh をバックグラウンド起動し、PID を state に記録して `connecting` へ遷移させる。**確立の完了は待たない** |
| `_ssh_is_alive <name>` | `ssh -O check` が 0 なら生存。ソケットが無い場合は `kill -0 <pid>` にフォールバック |
| `_ssh_stop <name>` | 停止手順（後述） |
| `_ssh_take_error <name>` | `err/<name>.err` の末尾から意味のある 1 行を抽出し、`_sanitize` して返す。読み取り後にファイルを切り詰める |

#### 起動コマンド

```bash
_SSH_ARGS=(ssh -N -T -M -S "$CTL"
  -o ControlMaster=yes
  -o ControlPersist=no
  -o ExitOnForwardFailure=yes
  -o BatchMode=yes
  -o NumberOfPasswordPrompts=0
  -o StrictHostKeyChecking=yes
  -o ConnectTimeout="$CONNECT_TIMEOUT"
  -o ServerAliveInterval="$SERVER_ALIVE_INTERVAL"
  -o ServerAliveCountMax="$SERVER_ALIVE_COUNT_MAX"
  -p "$PORT"
  -L "${BIND_ADDRESS}:${LOCAL_PORT}:${REMOTE_HOST}:${REMOTE_PORT}")
[[ -n "$IDENTITY" ]] && _SSH_ARGS+=(-o IdentitiesOnly=yes -i "$IDENTITY")
[[ -n "$USER_NAME" ]] && _SSH_ARGS+=(-l "$USER_NAME")
# ユーザー指定の ssh_options は既定の後に追加する（後勝ちで上書き可能）
for OPT in "${ENTRY_OPTS[@]}"; do _SSH_ARGS+=(-o "$OPT"); done
_SSH_ARGS+=("$HOST")

"${_SSH_ARGS[@]}" </dev/null >>"$ERR_FILE" 2>&1 &
PID=$!
```

各オプションの意図:

| オプション | 意図 |
| --- | --- |
| `-N -T` | コマンドを実行せず、擬似端末も割り当てない |
| `-M -S <path>` | ControlMaster を立て、`-O check` / `-O exit` による制御を可能にする |
| `ControlPersist=no` | マスタをこのプロセスに束縛し、孤児の常駐マスタを作らない |
| `ExitOnForwardFailure=yes` | ポート束縛に失敗したら ssh 自身を即終了させ、`process` チェックだけでも失敗を検知できるようにする（SPECS 4.2 の例では個別指定だが既定化する） |
| `BatchMode=yes` / `NumberOfPasswordPrompts=0` | 公開鍵認証のみとし、デーモンが対話入力で固まらないようにする（SPECS 1.3 / 9.2） |
| `StrictHostKeyChecking=yes` | 未登録ホストへは接続しない（SPECS 2.2）。`accept-new` にはしない |
| `IdentitiesOnly=yes` | `identity` 指定時に ssh-agent 内の別鍵を先に試して失敗するのを防ぐ |

#### 停止手順（`_ssh_stop`）

```
1. ssh -O exit -S <ctl> <host>   … 成功したら最大 2 秒、プロセス消滅を 0.1 秒間隔で待つ
2. まだ生きていれば kill -TERM <pid>  … 最大 3 秒待つ
3. まだ生きていれば kill -KILL <pid>
4. ControlPath のソケットファイルが残っていれば削除する
5. state の pid を 0 にする
```

`ssh -O exit` は ControlPath が無効な場合に非 0 で返るため、必ず PID による強制終了までのフォールバックを持つ。SPECS 5.4 の「孤児プロセスを残さない」要件はこの手順で担保する。

### 5.6 死活監視

| 関数 | 引数 | 戻り値 | 説明 |
| --- | --- | --- | --- |
| `_probe_detect` | - | - | 起動時に 1 回だけ、`/dev/tcp` が使えるかを自己テストし `_PROBE_BACKEND` に `devtcp` / `nc` / `none` を設定する |
| `_probe_tcp <addr> <port>` | - | 0=接続可 / 1=拒否 | TCP 接続の可否のみ判定 |
| `_probe_forward <addr> <port>` | - | 0=転送成立 / 1=即切断 / 2=接続不可 | 接続後の即時 EOF を検出する（下記） |
| `_is_port_free <addr> <port>` | - | 0=空き / 1=使用中 | `_probe_tcp` が接続できたら使用中 |
| `_health_check <name>` | - | 0=正常 / 1=異常 | `check_mode` に応じて判定を切り替える |

#### `remote` 判定の原理

OpenSSH のローカルフォワードは、ローカルポートへの接続を受理した後に転送先へのチャネルを開き、**失敗するとローカル側の接続を即座に閉じる**。この挙動を利用する。

```bash
# _probe_forward <addr> <port>
exec 3<>"/dev/tcp/${ADDR}/${PORT}" 2>/dev/null || return 2   # 接続できない
read -t "$_REMOTE_PROBE_WAIT" -N 1 -u 3 _DUMMY
local RC=$?
exec 3<&- 3>&-
(( RC == 0 ))   && return 0   # データを受信した        = 転送先まで到達している
(( RC > 128 ))  && return 0   # 待機タイムアウト        = 接続が維持されている = 到達している
return 1                      # RC == 1 (EOF)          = 転送先へ届かず即切断された
```

- `_REMOTE_PROBE_WAIT` の既定は **1.0 秒**（`read -t` の小数指定は bash 4 で利用可）。
- データを送信せずに切断するため、SPECS 5.2 の「ハンドシェイク成立の確認のみ」を満たす。
- **限界**: 転送先が RST を返さず無応答のままタイムアウトする場合、1 秒の待機内では区別できず「正常」と誤判定する。この場合は ssh 側の `ServerAliveInterval` によるセッション断か、次サイクル以降での検知に委ねる。設計上の既知の制約として扱う。

#### `_PROBE_BACKEND` によるフォールバック

| バックエンド | 条件 | `tcp` | `remote` |
| --- | --- | --- | --- |
| `devtcp` | bash が `/dev/tcp` を利用可能（既定） | 可 | 可 |
| `nc` | `/dev/tcp` 不可、`nc` あり | `nc -z -w 1` で可 | **不可**。起動時に 1 回 WARN を出し、`tcp` 相当に劣化する |
| `none` | どちらも無い | 不可 | 不可。`check_mode` を `process` に強制し WARN を出す |

#### `check_mode` 別の判定

| モード | 実装 |
| --- | --- |
| `process` | `_ssh_is_alive` |
| `tcp` | `_ssh_is_alive` かつ `_probe_tcp <bind_address> <local_port>` |
| `remote` | `_ssh_is_alive` かつ `_probe_forward ... == 0` |

**接続確立の判定（`connecting` → `connected`）は `check_mode` に関わらず `tcp` 相当で行う。** 確立直後は転送先の応答が遅れうるため、`remote` 判定を最初のサイクルから適用すると誤って失敗と見なす恐れがあるためである。`remote` 判定は `connected` に入った後の定期監視から適用する。

### 5.7 デーモン

#### 状態遷移の実装（SPECS 5.1）

1 エントリ 1 サイクル分の遷移を `_daemon_tick_entry <name>` に閉じ込める。

```
NOW=$(_now)

case $status in
  connected)
    (( NOW < next_check_at )) && return
    if _health_check; then
      next_check_at = NOW + check_interval
      # 60 秒以上継続したらバックオフをリセット（SPECS 5.3）
      if (( NOW - connected_since >= 60 )); then
        backoff = retry_initial ; retry_count = 0
      fi
    else
      _log_warn "health check failed (...)"
      _ssh_stop
      _enter_retrying
    fi
    ;;

  connecting)
    if ! _ssh_is_alive; then
      last_error = _ssh_take_error       # ssh が即死 → stderr から理由を取得
      _enter_retrying
    elif _probe_tcp bind local_port; then
      _state_transit connected
      connected_since = NOW
      next_check_at = NOW + check_interval
      _log_info "connection established (pid=...)"
    elif (( NOW - since >= connect_timeout + 2 )); then
      _ssh_stop
      last_error = "connection did not become ready within ${connect_timeout}s"
      _enter_retrying
    fi
    ;;

  retrying)
    (( NOW < next_retry_at )) && return
    if (( retry_limit > 0 && retry_count >= retry_limit )); then
      _state_transit failed "retry limit reached"
      return
    fi
    if ! _is_port_free bind local_port; then
      # SPECS 5.3: ローカルポート使用中は再試行せず即 failed
      _state_transit failed "local port ... is already in use by another process"
      return
    fi
    _ssh_start        # → connecting
    ;;

  stopped|disabled|failed)
    : # デーモンからは何もしない。desired の変更（reconcile）でのみ復帰する
    ;;
esac
```

`_enter_retrying` の内容:

```
retry_count += 1
backoff = (retry_count == 1) ? retry_initial : min(backoff * 2, retry_max)
next_retry_at = NOW + backoff
_state_transit retrying
_log_info "reconnecting in ${backoff}s (attempt ${retry_count})"
```

#### 希望状態との照合（`_daemon_reconcile`）

各エントリについて desired と現在の status を突き合わせる。SIGUSR1 受信時、および reload 後に実行する。

| desired | status | 動作 |
| --- | --- | --- |
| `up` | `stopped` / `disabled` / `failed` | バックオフ状態をリセットし、即座に `_ssh_start`（`retry_count=0`、`backoff=retry_initial`）。`failed` からの復帰は SPECS 5.3 の `restart` 経路にあたる |
| `up` | `connected` / `connecting` / `retrying` | 何もしない（冪等） |
| `down` | `connected` / `connecting` / `retrying` | `_ssh_stop` して `stopped` |
| `down` | `stopped` / `disabled` / `failed` | 何もしない（冪等） |

`enabled: false` のエントリは desired ファイルが無い限り `disabled` を維持する。`pfwd start <名前>` で明示指定された場合は desired=up が書かれるため起動する（SPECS 3.1 の「省略時は enabled な全エントリ」＝名前を明示すれば `enabled: false` でも起動する、という解釈）。

#### メインループ

```
_daemon_main:
  umask 077
  _daemon_lock_acquire            # 失敗 → 終了コード 6
  trap '_on_term' TERM INT
  trap '_on_hup'  HUP
  trap '_on_usr1' USR1
  _config_load / _config_validate / _log_init / _probe_detect
  _daemon_init_states             # state を読み直し、desired を初期化し、監視時刻を分散させる
  _daemon_reconcile
  _log_info - "daemon started (pid=$$, entries=N)"

  while [[ -z "$_SHUTDOWN" ]]; do
    (( _FLAG_HUP  )) && { _FLAG_HUP=0;  _daemon_reload; }
    (( _FLAG_USR1 )) && { _FLAG_USR1=0; _daemon_reconcile; }
    for NAME in "${_CFG_NAMES[@]}"; do
      _daemon_tick_entry "$NAME"
    done
    _daemon_flush_states          # 変更のあったエントリのみ書き出す
    sleep 1
  done
  _daemon_shutdown
```

- ループ周期は **1 秒固定**。エントリごとの `check_interval` は `next_check_at` で管理する。周期を 1 秒にするのは、シグナル（`stop` の即応）と再試行タイマの粒度を揃えるため。
- bash は前景コマンドの完了後にトラップを実行するため、シグナル応答の遅延は最大 1 秒に収まる。
- シグナルハンドラはフラグを立てるだけにする（ハンドラ内で重い処理をしない）。

#### 監視時刻の分散

`_daemon_init_states` で `next_check_at = NOW + (index % check_interval)` として初期化し、100 エントリが同一サイクルに集中しないようにする。さらに 1 サイクルあたりの死活監視実行数を `_MAX_CHECKS_PER_TICK`（既定 20）で上限を設ける。上限に達した分は次サイクルに繰り越す。

- `remote` チェックの最悪所要時間は `_REMOTE_PROBE_WAIT`（1.0 秒）。20 件 × 1.0 秒 = 最悪 20 秒。
- ただし正常時のプローブは接続維持を確認した時点（≒ 待機タイムアウト）で終わるため、実測はこれより短い。
- 100 エントリ・`check_interval=30` の場合、1 秒あたりの平均チェック数は 3.3 件であり、上限には通常到達しない。

#### `reload` の差分反映（SPECS 5.5）

```
_daemon_reload:
  旧 _CFG を _CFG_OLD に退避し、設定を読み直す
  for NAME in 新設定のエントリ:
    if NAME が旧に無い          -> state 初期化、desired=enabled、起動対象へ
    elif conn_sig が変化         -> _ssh_stop してから再起動（connecting へ）
    elif enabled が false になった -> _ssh_stop、desired ファイル削除、disabled へ
    else                         -> セッション維持（description / check_mode / check_interval のみ更新）
  for NAME in 旧設定にあり新設定に無いエントリ:
    _ssh_stop; _state_remove
  global の変更は次サイクルから反映（既存セッションは維持）
  _log_info - "config reloaded (added=A, removed=R, restarted=U)"
```

設定の再読み込みに失敗した場合（構文エラーなど）は、**旧設定を維持したまま** ERROR をログに記録して継続する。デーモンは落とさない。

#### 終了処理

```
_daemon_shutdown:
  _log_info - "shutting down"
  for NAME in "${_CFG_NAMES[@]}": _ssh_stop "$NAME"   # 逆順ではなく定義順で可
  全エントリの status を stopped にして flush
  daemon.pid / daemon.lock を削除
  exit 0
```

### 5.8 排他制御

| 対象 | 方式 |
| --- | --- |
| デーモンの二重起動防止 | `mkdir "$_RUN_DIR/daemon.lock"` の原子性を利用する。成功したら中に `pid` を書く。`flock` は macOS に標準では無いため使わない |
| stale ロック | ロック取得に失敗したら `daemon.lock/pid` を読み、`kill -0` で生存確認する。死んでいれば ロックを削除して 1 回だけ再取得を試みる。ログに WARN を残す |
| state ファイル | 書き手はデーモンのみ。`mv` によるアトミック置換 |
| desired ファイル | 書き手は CLI のみ。`mv` によるアトミック置換。複数の CLI が同時に別エントリを操作しても衝突しない |
| ログファイル | 追記のみ（`>>`）。1 行が PIPE_BUF 未満のため行の混在は起きない |

### 5.9 CLI サブコマンド

| 関数 | 実装概要 |
| --- | --- |
| `_cmd_status` | デーモンの生死を判定 → state を読み表示。デーモン未起動時は先頭に `daemon: not running` を出し、各エントリは ControlPath ソケットの存在と `kill -0 <pid>` で実プロセス判定する（`ssh -O check` は N 回のプロセス起動になるため使わない）。`--exit-code` 指定時は `connected` 以外が 1 つでもあれば終了コード 4 |
| `_cmd_list` | 設定のみを読んで表示。state / プロセスには一切触れない |
| `_cmd_start` | デーモン生存確認（無ければ終了コード 5）→ 対象名解決 → 既に `connected` なら `[ SKIP ]` → `_desired_set up` → SIGUSR1 → `_wait_result` で結果表示 |
| `_cmd_stop` | 同様に `_desired_set down` → SIGUSR1 → 停止確認 |
| `_cmd_restart` | `_cmd_stop` 相当の完了を待ってから `_cmd_start` 相当を行う。`failed` からの復帰経路でもある（バックオフをリセットするため、desired を一度 `down` にしてから `up` にする） |
| `_cmd_daemon` | `_daemon_main` をフォアグラウンドで実行 |
| `_cmd_up` | 二重起動チェック → `setsid`（無ければ `nohup`）で `pfwd daemon` を起動し、`daemon.pid` の生成を最大 5 秒待つ |
| `_cmd_down` | `daemon.pid` に SIGTERM → 最大 15 秒、PID 消滅を待つ。時間切れなら SIGKILL し、残存 ssh を ControlPath 経由で掃除する |
| `_cmd_reload` | デーモンに SIGHUP → 完了を `daemon.meta` の更新時刻で確認（最大 5 秒） |
| `_cmd_logs` | `log_file` 未指定時は systemd / launchd のログ参照方法を案内して終了（SPECS 6.5）。指定時は `tail`（`-f` なら `tail -f`）。エントリ名指定時は `grep -F "[<name>]"` でフィルタする |
| `_cmd_test` | 設定検証 + `ssh -o BatchMode=yes -O none` ではなく、`ssh <共通オプション> -o ConnectTimeout=N <host> true` で到達性を確認し、`_is_port_free` でローカルポートを確認する。**フォワードは張らない**。結果を `[  OK  ]` / `[ WARN ]` / `[FAILED]` で表示し、失敗があれば終了コード 4 |
| `_cmd_install_service` | macOS では非対応エラー。`--user`（既定） / `--system` / `--run-as` / `--now` を解析し、heredoc で unit を生成する |
| `_cmd_uninstall_service` | unit を停止・disable してから削除する |
| `_cmd_config` | `--init` / `--force` / 引数なし（パス表示）。位置引数は受け付けず、渡されたら `_usage` で終了コード 2 とする（既定パスへの意図しない作成を防ぐため）。`--init` の作成先は `_OPT_CONFIG` があればそれ（`_expand_tilde` 済み）、無ければ `_config_user_path`。作成先が `_config_find` の探索候補（`_config_user_path` / `/etc/port-forwarder/config.yaml`）以外なら、`_config_init` が `Note:` 行で以降も `-c` が要る旨を案内する |
| `_cmd_version` / `_cmd_help` | `_VERSION` の表示、サブコマンド別ヘルプ |

#### `_wait_result <name...> <期待状態> <タイムアウト>`

CLI は desired を書いて SIGUSR1 を送った後、state ファイルをポーリング（0.2 秒間隔）して結果を表示する。

- `start`: `connected` になれば `[  OK  ]`、`failed` になれば `[FAILED]` + `last_error`、タイムアウト（`connect_timeout + 5` 秒）なら現在の状態をそのまま表示する。
- `stop`: `stopped` になれば `[  OK  ]`。タイムアウトは 10 秒。
- 1 つでも失敗があれば終了コード 4（SPECS 7 章）。

#### 引数解析

値なしロングオプションを一括で `--foo` → `_FOO=yes` に変換する簡易方式では `--config <PATH>` のような値付きオプションを扱えないため、**統合パーサ `_parse_args`** を実装する。簡易方式を採らない理由はソースコメントにも明記する。

```
_parse_args "$@":
  while 引数が残る:
    case $1 in
      -c|--config)    _OPT_CONFIG=$2; shift 2 ;;
      --config=*)     _OPT_CONFIG=${1#*=}; shift ;;
      -v|--verbose)   _VERBOSE=$((_VERBOSE + 1)); shift ;;
      -vv)            _VERBOSE=2; shift ;;
      -q|--quiet)     _QUIET=yes; shift ;;
      --no-color)     _NO_COLOR=yes; shift ;;
      -h|--help)      _OPT_HELP=yes; shift ;;
      -V|--version)   _OPT_VERSION=yes; shift ;;
      --)             shift; break ;;
      -*)             _usage "unknown option: $1" ;;   # 終了コード 2
      *)              サブコマンド未確定なら _SUBCMD=$1、確定済みなら _ARGS+=($1); shift ;;
    esac
  _ARGS+=("$@")
  [[ -z "$_SUBCMD" ]] && _SUBCMD=status     # SPECS 3.1: 引数なしは status
```

サブコマンド固有オプション（`--init` / `--force` / `--user` / `--system` / `--run-as` / `--now` / `-f` / `--exit-code`）は、共通パーサで未知として弾かれないよう `_SUBCMD_OPTS` に一旦収集し、各 `_cmd_*` 内で解析する。

#### 名前解決

```
_resolve_names <引数...>:
  引数が無ければ:
    start        -> enabled かつ有効なエントリすべて
    stop/restart -> 全エントリ
    status/test  -> 全エントリ
  引数があれば _CFG_NAMES に照合し、無いものは
    __show_error "no such entry 'db-pord'"
    exit 2
```

### 5.10 systemd unit の生成

`--user` の場合、`~/.config/systemd/user/port-forwarder.service` を生成する。

```ini
[Unit]
Description=port-forwarder: persistent SSH port forwarding
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=<実行ファイルの絶対パス> daemon
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10
KillMode=mixed
TimeoutStopSec=30

[Install]
WantedBy=default.target
```

- `ExecStart` のパスは `_self_path()` で解決した絶対パスを埋め込む（SPECS 9.1 の `/usr/local/bin/pfwd` は既定の例示）。
- `--system` の場合は `/etc/systemd/system/port-forwarder.service` に生成し、`User=<--run-as の値>` と `WantedBy=multi-user.target` を加える。`--run-as` 省略時は root 実行となるため警告を出す。
- `KillMode=mixed` により、停止時にメインプロセスへ SIGTERM が送られ、自前の `_daemon_shutdown` で子 ssh を確実に終了させられる。
- `--now` 指定時は `systemctl [--user] daemon-reload` と `enable --now` を実行する。省略時は SPECS 9.1 の通り実行すべきコマンドを表示するに留める。

---

## 6. 主要シーケンス

### 6.1 `pfwd up` → 接続確立

```
user            pfwd(CLI)              pfwd daemon                ssh
 │  up            │                        │                       │
 ├───────────────>│ ロック確認             │                       │
 │                ├── setsid pfwd daemon ─>│                       │
 │                │                        ├ ロック取得            │
 │                │                        ├ 設定読込・検証        │
 │                │                        ├ desired 初期化        │
 │                │                        ├ reconcile             │
 │                │                        ├── ssh -M -N -L ... ──>│ (背景起動)
 │                │                        │   status=connecting   │
 │                │<── daemon.pid 生成 ────┤                       │
 │<── 表示 ───────┤                        │                       │
 │                │                   [1 秒後のサイクル]           │
 │                │                        ├ _probe_tcp OK ────────┤
 │                │                        │   status=connected    │
 │                │                        ├ log: connection established
```

### 6.2 断検知 → 再接続

```
[サイクル N]  status=connected, now >= next_check_at
   _health_check(remote) → _probe_forward が即 EOF → 異常
   log WARN "health check failed (tcp 127.0.0.1:19090 refused)"
   _ssh_stop            (-O exit → TERM → KILL)
   retry_count=1, backoff=retry_initial(5), next_retry_at=now+5
   status=retrying
   log INFO "reconnecting in 5s (attempt 1)"

[サイクル N+5]  now >= next_retry_at
   _is_port_free? → No なら status=failed（再試行しない）
   _ssh_start → status=connecting

[サイクル N+6..]  確立できれば connected、
                  connect_timeout+2 を超えたら retrying（backoff は 10 → 20 → … retry_max で頭打ち）
                  connected が 60 秒継続したら backoff/retry_count をリセット
```

### 6.3 `pfwd stop db-prod`

```
CLI: daemon 生存確認（無ければ exit 5）
     state/db-prod.desired に "down" を書く（tmp + mv）
     kill -USR1 <daemon pid>
daemon: _FLAG_USR1=1 → 次サイクル先頭で _daemon_reconcile
        desired=down かつ status=connected → _ssh_stop → status=stopped → flush
CLI: state を 0.2 秒間隔でポーリング（最大 10 秒）
     status=stopped を確認 → "[  OK  ] db-prod    stopped"
```

### 6.4 `pfwd reload`

```
CLI: daemon 生存確認 → kill -HUP <pid> → daemon.meta の mtime 更新を待つ（最大 5 秒）
daemon: _FLAG_HUP=1 → 次サイクル先頭で _daemon_reload
        conn_sig 比較で 追加 / 削除 / 再起動 / 維持 を判定
        daemon.meta を更新（CLI への完了通知を兼ねる）
```

### 6.5 `pfwd down`

```
CLI: kill -TERM <pid>
daemon: trap TERM → _SHUTDOWN=1 → ループ脱出 → 全 _ssh_stop → state を stopped → ロック解放 → exit 0
CLI: PID 消滅を最大 15 秒待つ。時間切れなら SIGKILL し、
     ctl/*.sock に対して ssh -O exit で残存セッションを掃除してから警告を出す
```

---

## 7. エラー処理と終了コード

### 7.1 終了コード定数

```bash
readonly _EXIT_OK=0            # 正常終了
readonly _EXIT_ERROR=1         # 一般的な実行時エラー
readonly _EXIT_USAGE=2         # 引数・オプションの誤り、存在しないエントリ名
readonly _EXIT_CONFIG=3        # 設定ファイル未検出 / 解析失敗
readonly _EXIT_CONNECT=4       # 1 つ以上のエントリで接続失敗
readonly _EXIT_NO_DAEMON=5     # デーモン未起動
readonly _EXIT_RUNNING=6       # デーモン二重起動
readonly _EXIT_DEPS=7          # 依存コマンド不足
```

`__error_end` は常に 1 で終了するため、コードを指定する `_error_exit <code> <message...>` を新設し、終了コードを伴うエラーはすべてこれを通す。

### 7.2 前提チェック（起動直後）

`_check_prerequisites` を、引数解析の直後・設定読み込みの前に実行する。

| 検査 | 失敗時 |
| --- | --- |
| `BASH_VERSINFO[0] >= 4` | `_EXIT_DEPS`（`error: bash 4.0 or later is required (current: 3.2.57). On macOS: brew install bash`） |
| `ssh` の存在 | `_EXIT_DEPS` |
| `yq` の存在 | `_EXIT_DEPS`（SPECS 10 章の文言）。ただし `version` / `help` サブコマンドでは検査しない |
| `_RUN_DIR` の作成可否 | `_EXIT_ERROR` |

`yq` のバージョン判定は行わない（SPECS 2.1 の方針）。

**yq 実装の判定はここでは行わない。** クエリは両実装に共通なので（4.1）、正常時に判定する理由が無く、
`_check_prerequisites` で `yq --version` を起動すると起動時間の要件（8 章）に無駄が乗るだけになる。
判定は次の 2 箇所だけで走る。

| 契機 | 呼ぶもの | ふるまい |
| --- | --- | --- |
| クエリ 0 が非 0 で終了した | `_yq_diagnose` | Python 実装なら `command -v jq` も確認する。`jq` が無い／未知の実装なら `_EXIT_DEPS`。それ以外は解析失敗（終了コード 3）として報告する |
| `pfwd test` | `_yq_detect` | 判定結果を `yq:` 行に表示するだけで、未知の実装でも終了しない |

### 7.3 エラーメッセージの集約

SPECS 10 章の全パターンを `_err_*` 関数として定義し、メッセージ文字列をコード中に散在させない。

```bash
_err_no_config()      { echo "config file not found. Run 'pfwd config --init' to create one at $1"; }
_err_missing_key()    { echo "[$1] missing required key '$2' (entries.$1.$2)"; }
_err_dup_port()       { echo "local_port $1 is used by both [$2] and [$3]"; }
_err_port_in_use()    { echo "[$1] local port $2 is already in use by another process"; }
_err_unknown_host_key(){ echo "[$1] host key for $2 is not in known_hosts. Run: ssh-keyscan -H $2 >> ~/.ssh/known_hosts"; }
_err_key_perm()       { echo "[$1] identity file $2 has too open permissions ($3). Run: chmod 600 $2"; }
_err_no_command()     { echo "required command '$1' not found. Install it and make sure it is in your PATH."; }
_err_daemon_running() { echo "daemon is already running (pid $1). Use 'pfwd down' to stop it."; }
_err_no_daemon()      { echo "daemon is not running. Run 'pfwd up' to start it."; }
_err_no_entry()       { echo "no such entry '$1'"; }
_err_config_is_dir()  { echo "$1 is a directory. Specify the config file itself (e.g. $1/config.yaml)"; }
_err_config_no_args() { echo "'config' takes no arguments. Use 'pfwd --config <PATH> config --init' to choose where the file is created."; }
```

### 7.4 ssh 失敗理由の分類

`err/<name>.err` の内容をパターンマッチし、リトライの可否とメッセージを決める。

| パターン | 分類 | 動作 |
| --- | --- | --- |
| `Host key verification failed` / `No ... host key is known` | 設定不備 | 即 `failed`（SPECS 2.2） |
| `Permission denied (publickey` | 認証失敗 | 即 `failed` |
| `Enter passphrase` / `passphrase` を含む | パスフレーズ必要 | 即 `failed`。ログに `passphrase-protected key requires ssh-agent` を明示（SPECS 9.2） |
| `bind: Address already in use` / `cannot listen to port` | ローカルポート使用中 | 即 `failed`（SPECS 5.3） |
| `Connection timed out` / `Connection refused` / `Network is unreachable` / `Name or service not known` | 一時障害 | `retrying`（バックオフ） |
| その他 | 不明 | `retrying`（バックオフ） |

「即 `failed`」の分類は、リトライしても成功しえない事象に限定する。復帰には `pfwd restart <名前>` が必要（SPECS 5.3）。

---

## 8. 性能設計

| 要件（SPECS 11 章） | 実装上の担保 |
| --- | --- |
| `pfwd status` が 1 秒以内（50 エントリ） | 外部コマンド起動を「yq × 設定ファイル数（通常 5〜10 回）」に限定する。state の読み取りは bash 組み込みのみ。デーモン起動中は ssh を 1 回も起動しない |
| 平常時 CPU ほぼ 0%（30 秒間隔・10 エントリ） | ループ本体は `sleep 1` と数十回の算術比較のみ。監視が起きるサイクルでのみプローブを実行する。`date` は `printf '%(%s)T'` に置き換える |
| 100 エントリまで動作保証 | `next_check_at` の分散初期化と `_MAX_CHECKS_PER_TICK=20` により、1 サイクルの所要時間を有界にする |
| 復旧時間 ≤ `check_interval + retry_initial` | 監視周期 1 秒でタイマを評価するため、検知遅延は最大 1 秒。`next_check_at` 到達 → 即 `_ssh_stop` → `next_retry_at = now + retry_initial` で要件内に収まる |

yq 実装の判定（`_yq_detect`）は**正常経路の外部コマンド起動数を増やさない**。判定が走るのは解析に
失敗したときと `pfwd test` だけで、`status` / `list` / `up` などは `yq --version` を 1 回も起動しない
（7.2）。`_yq_kind` はループの外でしか呼ばず、ループ内の型判定は述語 `_yq_is_map` / `_yq_is_null` で
行う（サブシェルを起こさないため）。

---

## 9. セキュリティ設計

| 項目 | 実装 |
| --- | --- |
| 実行時ディレクトリ | `umask 077` を起動直後に設定し、`_RUN_DIR` は `0700` |
| 一時ディレクトリ | `__TMP_BASE` は `mkdir -m 700` で作る。`umask 077` の設定前や、関数定義だけを読み込む経路でも `0700` を保証するため、umask に依存させない |
| ログ | `_sanitize` を経由し、制御文字を除去する。ssh の stderr をそのまま転記しない（分類済みメッセージ + 該当行 1 行のみ） |
| 秘密情報 | 鍵の内容・パスフレーズは一切扱わない。`BatchMode=yes` により入力を要求しない。ホスト名・ユーザー名はログに出す（SPECS 11 章） |
| ホスト鍵 | `StrictHostKeyChecking=yes` を固定。ユーザーの `ssh_options` で `StrictHostKeyChecking=no` が指定された場合は**警告を出したうえで指定に従う**（ユーザーの明示的な選択を尊重する） |
| `bind_address` | `0.0.0.0` / `::` 指定時に `test` と `status` の初回起動時に警告を出す |
| 設定ファイル権限 | 他ユーザーから書き込み可能なら警告（実行は継続） |
| eval | 設定値に対して `eval` を使わない。state ファイルも `source` せず自前パースする |

---

## 10. テスト方針

bats-core を用いる。`PFWD_SOURCE_ONLY=1 source ./pfwd` で関数だけを読み込み、外部依存（ssh / yq / デーモン）はテスト用の関数で差し替える。

yq まわりは実 yq に依存しない形で検証する。

- 型名の正規化（`_yq_kind` / `_yq_is_map` / `_yq_is_null`）は純粋な関数として直接呼ぶ。
- 実装判定（`_yq_detect` / `_yq_diagnose`）は、`--version` の出力を返すだけの `yq` スタブを PATH の
  先頭に置いて確認する。冪等性はスタブにカウンタを持たせて起動回数で見る。
- **正常時に `--version` が 1 回も起動しないこと**（7.2 の方針の核心）も、カウンタ付きスタブ越しに
  `pfwd list` を通して回数で確認する。
- 両実装の突き合わせは任意テストとし、`PFWD_YQ_PYTHON` に kislyuk/yq のパスが渡されたときだけ走る。
  全 fixture について `pfwd list` の出力がバイト単位で一致することを見る。

### 10.1 構成

```
test/
├── helper.bash              共通セットアップ（PFWD_SOURCE_ONLY、一時 _RUN_DIR の作成）
├── fixtures/
│   ├── basic.yaml           SPECS 4.2 の例そのまま
│   ├── confd/*.yaml         マージ検証用
│   ├── invalid_syntax.yaml  YAML 構文エラー
│   ├── dup_port.yaml        local_port 重複
│   └── yq_edge.yaml         yq 実装差の境界（null / タブ / 改行 / global の混在型）
├── test_config.bats
├── test_yq.bats             yq 実装の判定と型名の正規化（スタブで検証）
├── test_validate.bats
├── test_state.bats
├── test_statemachine.bats
├── test_probe.bats
├── test_tmp.bats            一時ディレクトリのパス確定・遅延生成・削除
├── test_cli.bats
└── test_integration.bats    実際に localhost へ ssh する（環境変数で明示的に有効化）
```

### 10.2 テスト項目

| ファイル | 検証内容 |
| --- | --- |
| `test_config` | 探索順の優先順位 / `conf.d` の名前順マージ / global のキー単位後勝ち / entries のエントリ単位置換 / 記述順の保持 / `~` 展開 / `ssh_options` の配列読み込み / 既定値の適用 |
| `test_yq` | `_yq_kind` の正規化（両実装の表記＋空出力） / `_yq_is_map`・`_yq_is_null` の真偽 / `yq` スタブによる `_yq_detect` の分類と冪等性 / `_yq_diagnose` の終了コード 7（jq 不在・未知の実装） / 正常時に `--version` が起動しないこと / `pfwd test` の `yq:` 行 / `PFWD_YQ_PYTHON` があるときだけ走る両実装の突き合わせ |
| `test_validate` | 必須キー欠落 / ポート範囲外 / `local_port` 重複（両方無効化） / 不正なエントリ名 / 未知キーは警告のみ / `check_mode` 不正 / `enabled` の各表記 / 構文エラーで終了コード 3 / `entries` 空で終了コード 3 |
| `test_state` | state のアトミック書き込み / 読み書きの往復 / desired の既定値（ファイル無し時は `enabled` に従う） / `_state_transit` がログを 1 行出すこと |
| `test_statemachine` | `_daemon_tick_entry` を `_ssh_*` / `_health_check` のスタブと組み合わせ、SPECS 5.1 の全遷移を検証。バックオフ列（5→10→20→…→300 で頭打ち） / 60 秒継続でのリセット / `retry_limit` 到達で `failed` / ポート使用中で即 `failed` |
| `test_probe` | `nc -l` で立てたポートに対する `_probe_tcp` / 未使用ポートでの `_is_port_free` / 接続直後に閉じるサーバに対する `_probe_forward` が 1 を返すこと / 接続を保持するサーバに対して 0 を返すこと |
| `test_tmp` | `__TMP_BASE` が絶対パスで確定し source 時点では作られないこと / `__get_tmp_base` が同じ値を返すこと / `__make_tmp` の遅延生成と `0700` / 生成に失敗したら 1 を返すこと / コマンド置換越しに呼んでも親から同じディレクトリに届くこと / `__script_end_clean_tmp` の削除と、未生成でも 0 を返すこと |
| `test_cli` | 引数解析（`--config=` 形式を含む） / 引数なしで `status` になること / 未知エントリ名で終了コード 2 / デーモン未起動時の `start` が終了コード 5 / `--exit-code` の挙動 / `_fmt_uptime` の整形 / 出力表の桁揃え |
| `test_integration` | `PFWD_IT=1` のときのみ実行。`localhost` への ssh でデーモンを起動し、`up` → `status` → `stop` → `down` を通す。ssh プロセスを外部から kill して再接続を確認する |

### 10.3 静的検査

```
shellcheck -x -s bash pfwd
bash -n pfwd
```

CI での実行を前提に、shellcheck の指摘は 0 件を維持する（抑止コメントは理由付きで最小限）。

---

## 11. 実装順序

| # | 内容 | 完了条件 |
| --- | --- | --- |
| 1 | 骨格（ヘッダ・セクション枠・共通基盤関数の実装、引数解析、`version` / `help`） | `pfwd version` / `pfwd --help` が動く |
| 2 | 設定の読み込み・マージ・検証 + `list` / `config --init` | `test_config` / `test_validate` が通る |
| 3 | 状態管理とログ | `test_state` が通る |
| 4 | SSH セッション制御とプローブ | `test_probe` が通る。手動で `_ssh_start` / `_ssh_stop` が動く |
| 5 | デーモン（状態機械、reconcile、シグナル、ロック） | `test_statemachine` が通る。`daemon` をフォアグラウンドで実行して再接続を確認できる |
| 6 | CLI（`up` / `down` / `start` / `stop` / `restart` / `reload` / `status` / `logs`） | `test_cli` が通る。SPECS 6 章の出力と一致する |
| 7 | `test` サブコマンド | SPECS 6.4 の出力と一致する |
| 8 | `install-service` / `uninstall-service` | Linux で systemd 経由の起動・停止・reload が動く |
| 9 | 結合テストと文書整備 | `test_integration` が通る。SPECS_ja.md に 1.2 節の差分を反映する |

---

## 12. 未確定事項・将来対応

| 項目 | 現状の扱い | 備考 |
| --- | --- | --- |
| `remote` チェックの無応答タイムアウト | `_REMOTE_PROBE_WAIT` 1.0 秒で「到達」と判定する既知の制約 | 将来 `global.check_timeout` として公開し、待機時間を調整可能にする |
| `nc` フォールバック時の `remote` | `tcp` 相当に劣化（起動時に WARN） | `/dev/tcp` が無効な bash は稀のため v1.0 では許容する |
| ロック方式 | `mkdir` による原子性 | `flock` が両 OS で使えるようになれば置き換えを検討 |
| macOS のスリープ復帰 | 対応しない（SPECS 12 章） | `ServerAliveInterval` による断検知に委ねる |
| SPECS_ja.md の更新 | 1.2 節の 6 項目 | 反映済み（2026-09-08） |

---

<!-- vim: set ts=2 sw=2 sts=2 et nu : -->
