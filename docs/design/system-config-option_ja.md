---
title: --system でシステム全体設定 /etc/port-forwarder/config.yaml を扱えるようにする
created: 2026-09-13
updated: 2026-09-13
status: 実装中
---

# 要求

````text
# pfwd config --init の機能追加
`pfwd config --init --system` と実行すると、Linux環境では -c オプションで `/etc/port-forwarder/config.yaml` がconfig出力先に指定されたのと同じ動作とすること。
`-c` 指定時、 `--system` は無視される
Linux環境以外で --system が指定されたら、エラー終了

# pfwd install-service の機能追加
`pfwd install-service --system` では、configが /etc/port-forwarder/config.yaml にある前提で、ファイルの有無を調べること

`pfwd install-service --system` で、規定のconfigが存在しない場合は、先に `pfwd config --init --system` でconfigを作成するようにユーザーに案内すること
````

# 設計: `--system` によるシステム全体設定の取り扱い

## 目的

`--system` を「**システム全体設定（`/etc/port-forwarder/config.yaml`）を対象にする**」という 1 つの意味に統一し、システム常駐のセットアップを 2 コマンドで完結させる。

```console
$ sudo pfwd config --init --system      # /etc/port-forwarder/config.yaml を作る
$ sudo vi /etc/port-forwarder/config.yaml
$ sudo pfwd install-service --system --run-as komori --now
```

ユーザーから見て変わること:

- `pfwd config --init --system` が `/etc/port-forwarder/config.yaml` に雛形を作る（今日は `unknown option for 'config': --system` で終了コード 2）
- `pfwd install-service --system` が `/etc/port-forwarder/config.yaml` **だけ**を見て、無ければ `pfwd config --init --system` を案内する（今日はユーザー設定にフォールバックし、どちらも無ければユーザーパスを指した紛らわしいエラーになる）
- `pfwd install-service --system` が生成する unit の `ExecStart` に `--config /etc/port-forwarder/config.yaml` が入る
- `/etc` に書けないときに嘘の `Created:` が出なくなる（後述の現状バグ）

**変わらないもの**: `--system` を付けない既定経路（`config --init` / `config` / `install-service --user`）の出力・終了コード・生成されるテンプレート本文と unit 本文は一切変えない。SPECS 4.1 の設定探索順そのものも変えない。

## 現状（出発点）

### 読んだ既存設計文書

| 文書 | 状態 |
| --- | --- |
| `docs/SPECS_ja.md` | 存在。外部仕様の正典。**3.2 共通オプション**（`-c, --config <PATH>`）、**4.1 配置場所**（探索順に `/etc/port-forwarder/config.yaml` を含む）、**4.5 雛形生成**、**8 章 システム全体運用**（489 行、設定は `/etc/port-forwarder/`）、**9.1 Linux（systemd）**（`install-service --system` / `--run-as`）、**10 章 エラーメッセージ方針**が今回の設計を縛る |
| `docs/SPECS.md` | 上記の英訳。日本語版に従属（`CLAUDE.md`「Handling Documentation」） |
| `docs/DESIGN_ja.md` | 内部設計書（`ARCHITECTURE.md` 相当）。**3.3 実行時ディレクトリ**（167 行、システム判定は「EUID 0 かつ `/etc/port-forwarder/config.yaml` を採用」）、**5 章 関数表**の `_config_find`（380 行） / `_cmd_config`（696 行） / `_cmd_install_service`（694 行）、**7.3 エラーメッセージ集約**が該当 |
| `ARCHITECTURE.md` / `SPECS.md`（リポジトリ直下） | **無い**。`docs/` 配下の上記 3 本がその役割を担う |
| `docs/design/config-init-destination_ja.md` | 先行設計書（実装済み）。`config --init` の作成先を `-c` で指定する仕様を確立した。今回はその上に `--system` という別名を 1 つ足す形になるため、**決定 #1 / #5 はこの設計書と整合させる必要がある** |

`SPECS_ja.md` は `SPEC-xxx` 形式の ID 体系を持たないため、以降は節番号で名指す。

**SPECS 4.5（雛形生成）にも 9.1（systemd）にも `--system` で設定ファイルを扱う記述は無い。** 9.1 の `--system` は「システム単位の unit を生成する」という unit の置き場所の話だけで、設定ファイルがどこにあるかには触れていない。つまり今回は 4.5 については**新しい振る舞いの追加**、9.1 については**既存記述の改訂**にあたる。

### 現在の配線

| 場所 | 内容 |
| --- | --- |
| `pfwd:2834` `_parse_args` | `--system` は既に値なしオプションとして `_SUBCMD_OPTS` に収集される（`--init\|--force\|--user\|--system\|--now\|--exit-code\|-f`）。**パーサ側の変更は不要** |
| `pfwd:2144` `_cmd_config` | `_SUBCMD_OPTS` を走査し `--init` / `--force` だけ受ける。それ以外は `_usage "unknown option for 'config': ..."` で終了コード 2。したがって `config --init --system` は今日エラーになる |
| 同上 | `--init` の作成先は `_OPT_CONFIG` があれば `_expand_tilde` 済みの値、無ければ `_config_user_path` |
| `pfwd:956` `_config_init <PATH> <FORCE>` | ディレクトリ判定 → 既存ファイル判定 → `mkdir -p` → `cat > "$PATH_" <<'PFWD_CONFIG_TEMPLATE'` → `chmod 600` → `Created:` 2 行 → 既定探索パス以外なら `Note:` 行 |
| `pfwd:545` `_config_find` | `_OPT_CONFIG` 指定時はそのパス（無ければ終了コード 3）。未指定時の候補は `_config_user_path` と `'/etc/port-forwarder/config.yaml'`（555 行、**リテラル**） |
| `pfwd:1021` `_setup_runtime_dir` | `(( EUID == 0 )) && [[ "$_CONFIG_FILE" == '/etc/port-forwarder/'* ]]` でシステム扱いにし `_RUN_DIR=/run/port-forwarder` にする（**リテラル 2 箇所目**） |
| `pfwd:1004` `_config_init` の `Note:` 判定 | `[[ "$PATH_" != "$(_config_user_path)" && "$PATH_" != '/etc/port-forwarder/config.yaml' ]]`（**リテラル 3 箇所目**）。つまり `/etc` 宛に作ったときは既に `Note:` 行が出ない |
| `pfwd:2721` `_cmd_install_service` | Darwin なら終了コード 1。`--user`（既定） / `--system` / `--run-as` / `--now` を解析。`EXEC` は `_self_path()` に、**`_OPT_CONFIG` があるときだけ** `--config ${_CONFIG_FILE}` を足して `daemon` を付ける |
| `pfwd:2976` main dispatch | `install-service` は `_check_prerequisites` → **`_config_setup`** → `_cmd_install_service` の順。**`_config_setup` が `_cmd_install_service` より先に走るため、`--system` が判明する前に設定ファイルが解決される** |
| `pfwd:937` `_config_setup` | `_config_find` → `_config_file_list` → 各ファイルを `_config_parse_file` → エントリ 0 件なら終了コード 3 → `_config_apply_defaults` → `_config_validate` → `_config_check_perms` |

#### 現状の 2 つの不具合

**(a) `install-service --system` がユーザー設定を拾う。** dispatch の `_config_setup` は `--system` を知らないので `_config_find` の通常探索を行う。`~/.config/port-forwarder/config.yaml` があればそれが `_CONFIG_FILE` になり、`/etc` は見られない。`--run-as komori` を付けた system unit は `User=komori` で動くため、`ExecStart` に `--config` が入らない現状では daemon 側も `komori` のユーザー設定を先に拾う。**install 時に検証した設定と daemon が実際に読む設定が一致しない。**

**(b) 書き込みに失敗しても `Created:` と表示される。** `_config_init` の `cat > "$PATH_" <<'...'` はリダイレクトが失敗すると `bash: ...: Permission denied` を出して戻り値 1 になるが、`pfwd` は `set -e` を使わない方針（DESIGN 2.2）なので処理はそのまま続き、`chmod 600 ... 2>/dev/null` が黙って失敗したあと **`Created: /etc/port-forwarder/config.yaml` を出して終了コード 0 で終わる**。今日は既定の作成先が必ず書けるパスなので顕在化していないが、`--system` を入れると「`sudo` を忘れた」という最も起こりやすい操作でこれを踏む。実測で確認済み:

```console
$ bash -c 'cat > /etc/nope <<EOF
hi
EOF
echo "rc=$?"'
bash: /etc/nope: Permission denied
rc=1          # ← 失敗しているが処理は続く
```

### 既にあって使えるもの

- `_SUBCMD_OPTS` と `_parse_args` の値なしオプション一括収集 ── `--system` は既に通る。パーサ変更不要
- `_OPT_CONFIG` / `_CONFIG_FILE` ── `_OPT_CONFIG` に値を入れれば `_config_find` の固定パス経路と `_cmd_install_service` の `ExecStart` 埋め込みが**同時に**有効になる（決定 #6）
- `_config_user_path`（`pfwd:535`）── 既定パス判定の前例。`/etc` 側も同じ形にできる
- `_error_exit <CODE> <MSG>`（`pfwd:328`） / `_usage <MSG>`（`pfwd:1929`、usage を出して終了コード 2） / `__show_warn`（`pfwd:198`、`[ WARN ]` を stderr へ。`-q` で抑制される）
- `_err_*` 関数群（`pfwd:436-452`）── DESIGN 7.3 のエラーメッセージ集約先
- `_EXIT_*` 定数（`pfwd:45-52`。数値のハードコード禁止）
- `_service_unit_text <SCOPE> <RUN_AS> <EXEC>`（`pfwd:2693`）── unit 本文を純粋に組み立てる関数。`test/test_cli.bats:258` が直接呼んで検証しており、`EXEC` を差し替えるだけで新しい `ExecStart` を検証できる
- `test/test_cli.bats:276` ── `[ "$(uname)" = 'Darwin' ] || skip` というプラットフォーム依存テストの前例
- `test/helper.bash` ── `PFWD_SOURCE_ONLY=1` でファイルスコープ source するため、テストから `_SYSTEM_CONFIG` のようなグローバルを一時ディレクトリへ差し替えられる（決定 #10）

## 決定

| # | 論点 | 決定 | 理由 |
| --- | --- | --- | --- |
| 1 | `config --init --system` の意味 | `-c /etc/port-forwarder/config.yaml` を指定したのと**同じ経路**に落とす。`_cmd_config` で `TARGET` を決めるだけで、`_config_init` 側には `--system` を渡さない | 要求そのもの。`_config_init` に系統を増やさなければ、`Created:` / `Note:` / ディレクトリ判定 / 既存ファイル判定の既存挙動がそのまま効く。`/etc/...` は `_config_find` の探索候補なので `Note:` 行は出ない（現状の `pfwd:1004` の判定がそのまま正しく働く） |
| 2 | `-c` と `--system` の併用 | `-c` を優先し `--system` を無視する。ただし `__show_warn` で `--system is ignored because --config was given` を stderr に 1 行出す | 要求が「`-c` 指定時、`--system` は無視される」と明示。黙って無視すると `--system` と書いたのに `/etc` に作られないことに気づけない。**ユーザー確認済み** |
| 3 | #2 のとき非 Linux 判定を行うか | **行わない。** `-c` があれば `--system` は platform チェックも含めて完全に無効 | 「無視される」と決めたオプションで終了するのは矛盾する。`-c` で明示されたパスに作る動作は Linux 固有の話ではない |
| 4 | 非 Linux で `--system` | `uname` が `Linux` 以外なら `_EXIT_ERROR`（1）で終了する。判定は `Darwin` 限定にせず「Linux 以外」とする | 要求が「Linux環境以外で」と書いている。`/etc/port-forwarder` とシステム常駐（SPECS 8 / 9）は Linux + systemd 前提。既存の `install-service` の macOS ガード（`pfwd:2724`）と同じ終了コードに揃える |
| 5 | `--system` を `config` のどのサブオプションで受けるか | `--init` と併用したときだけ有効。`pfwd config --system`（`--init` なし）は `_usage` で終了コード 2 | パス表示だけの `config` に `--system` を効かせると「システム設定のパスを表示する」という要求に無い振る舞いを足すことになる。無視して黙って通すと #2 と一貫しない |
| 6 | `install-service --system` の設定解決 | `_cmd_install_service` の中で、`-c` 未指定なら `_OPT_CONFIG=/etc/port-forwarder/config.yaml` を**代入してから** `_config_setup` を呼ぶ | 1 つの代入で (a) `_config_find` が `/etc` 固定になる (b) 既存の `[[ -n "$_OPT_CONFIG" ]]` 分岐により `ExecStart` に `--config /etc/port-forwarder/config.yaml` が入る（決定 #8）── の両方が満たされる。新しい分岐を増やさない |
| 7 | `install-service --system` のチェック範囲 | ファイルの存在確認に加えて、従来どおり `_config_setup`（parse + validate + 権限チェック）を通す | 要求は「ファイルの有無を調べること」だが、現状の `install-service` は既に完全な検証を通している。存在確認だけに弱めると、壊れた設定で unit を作って `systemctl enable --now` まで走らせてしまう。**ユーザー確認済み** |
| 8 | system unit の `ExecStart` | `--system` のとき `--config /etc/port-forwarder/config.yaml` を埋め込む | `--run-as USER` を付けた system unit は `User=USER` で動くため、埋め込まないと daemon は SPECS 4.1 の探索順どおり `USER` のユーザー設定を**先に**拾う。install 時に検証したファイルと daemon が読むファイルを一致させる（現状不具合 (a)）。**ユーザー確認済み** |
| 9 | `/etc` の config が無いときの案内 | `_EXIT_CONFIG`（3）で終了し、`Run 'pfwd config --init --system' to create it (needs root)` を案内する。専用の `_err_*` 関数にする | 要求そのもの。既存の `_err_no_config`（`pfwd:436`）は `config --init`（`--system` なし）を案内するため、そのまま使うと**ユーザーパスに作る**間違った手順に導く。終了コードは `_err_no_config` の 3 に揃える |
| 10 | `/etc/port-forwarder/config.yaml` リテラルの重複 | 定数 `_SYSTEM_CONFIG_DIR` / `_SYSTEM_CONFIG` を「internal constants」節に追加し、既存 3 箇所（`pfwd:555` / `1004` / `1022`）と新規箇所をすべてこれに差し替える | `--system` で参照箇所が 3→6 に増える。先行設計書 `docs/design/tmp-base-single-source_ja.md` と同じ「パスは 1 箇所」方針。テストから一時ディレクトリへ差し替えられるようになり、root なしで検証できる（検証節） |
| 11 | 書き込み失敗の検知（現状不具合 (b)） | `cat 2>/dev/null > "$PATH_" <<'...'` とリダイレクト順を入れ替えて bash のエラーを捨て、戻り値を見て `_error_exit` する。`mkdir -p` 失敗時のメッセージにも root の案内を足す | `> "$PATH_"` より**先に** `2>/dev/null` を置かないとシェルのリダイレクトエラーが素通りする（実測で確認）。`EUID != 0` の門番にしないのは、`/etc/port-forwarder` が書ける運用（グループ権限など）を塞がないため。**ユーザー確認済み** |
| 12 | `install-service` / `uninstall-service` の既存 macOS ガード | 現状のまま（`Darwin` 判定、終了コード 1）残す | #4 の Linux チェックは `--system` を見たときに走るので、`install-service --system` は非 Linux で必ず弾かれる。既存ガードの条件を広げると、要求の範囲外で `--user` の挙動が変わる |
| 13 | `_setup_runtime_dir` のシステム判定 | 条件式は変えず、リテラルを `_SYSTEM_CONFIG_DIR` に差し替えるだけ | DESIGN 3.3 の「EUID 0 かつ `/etc/port-forwarder/` 配下」という判定は変えない。`--system` で `_CONFIG_FILE` が `/etc/...` になるので、**判定に手を入れなくても** `sudo pfwd daemon` が `/run/port-forwarder` を使う既存仕様に自然に乗る |

## 変更点

### 1. `pfwd` ─ システム設定パスの定数化（internal constants 節, 54 行付近）

決定 #10。

```bash
_SYSTEM_CONFIG_DIR='/etc/port-forwarder'                       # system-wide config dir (SPECS 4.1)
_SYSTEM_CONFIG="${_SYSTEM_CONFIG_DIR}/config.yaml"
```

差し替える既存箇所:

| 箇所 | 変更前 | 変更後 |
| --- | --- | --- |
| `pfwd:555` `_config_find` | `CANDIDATES+=('/etc/port-forwarder/config.yaml')` | `CANDIDATES+=("$_SYSTEM_CONFIG")` |
| `pfwd:1004` `_config_init` | `[[ "$PATH_" != '/etc/port-forwarder/config.yaml' ]]` | `[[ "$PATH_" != "$_SYSTEM_CONFIG" ]]` |
| `pfwd:1022` `_setup_runtime_dir` | `[[ "$_CONFIG_FILE" == '/etc/port-forwarder/'* ]]` | `[[ "$_CONFIG_FILE" == "${_SYSTEM_CONFIG_DIR}/"* ]]`（決定 #13） |

### 2. `pfwd` ─ エラーメッセージ関数の追加（`_err_*` 節, 452 行付近）

決定 #4 / #5 / #9 / #11。DESIGN 7.3「エラーメッセージは `_err_*` に集約」、SPECS 10 章の「何が / なぜ / どうすれば」に沿う。

```bash
_err_system_not_linux()   { echo "--system is for Linux (systemd) only ... (uname: $1)"; }
_err_system_needs_init()  { echo "'--system' requires '--init' ... use '${__SCRIPT_NAME} config' to show the path in use."; }
_err_no_system_config()   { echo "system config file not found: $1. Run 'sudo ${__SCRIPT_NAME} config --init --system' to create it."; }
_err_config_not_writable(){ echo "cannot write the config file: $1. Creating a file there needs write permission — rerun with sudo."; }
_err_config_mkdir()       { echo "cannot create the directory: $1. Creating it there needs write permission — rerun with sudo."; }
```

`_err_config_mkdir` は `_config_init` の既存インライン文言（`"cannot create directory: ${DIR}"`）を置き換える。

### 3. `pfwd` ─ 共有ヘルパ `_require_linux`（utility 節）

決定 #4。`config` と `install-service` の両方から呼ぶため 1 箇所にまとめる。

```bash
# --system targets /etc and systemd, which only exist on Linux (SPECS 8 / 9)
_require_linux() {
  local OS
  OS=$(uname)
  [[ "$OS" == 'Linux' ]] && return 0
  _error_exit "$_EXIT_ERROR" "$(_err_system_not_linux "$OS")"
}
```

### 4. `pfwd` ─ `_cmd_config`（2144 行）に `--system` を追加

決定 #1 / #2 / #3 / #5。作成先の決定だけを担う純粋な関数 `_config_init_target` に切り出し、テストから検証できるようにする（決定 #10 / 検証節）。

```bash
# decide where 'config --init' writes (SPECS 4.5)
_config_init_target() {
  local SYSTEM=$1
  if [[ -n "$_OPT_CONFIG" ]]; then
    # -c wins; --system is ignored but must not be silently dropped (決定 #2)
    [[ -n "$SYSTEM" ]] && __show_warn '--system is ignored because --config was given'
    _expand_tilde "$_OPT_CONFIG"
    return 0
  fi
  if [[ -n "$SYSTEM" ]]; then
    _require_linux                 # 決定 #4
    printf '%s\n' "$_SYSTEM_CONFIG"
    return 0
  fi
  _config_user_path
}
```

`_cmd_config` 側は `--system` を受け取り、`--init` が無ければ usage で抜ける。

```bash
_cmd_config() {
  local OPT TARGET F INIT='' FORCE='' SYSTEM=''
  (( ${#_ARGS[@]} > 0 )) && _usage "$(_err_config_no_args)"      # 既存のまま
  for OPT in "${_SUBCMD_OPTS[@]}"; do
    case "$OPT" in
      --init)   INIT=yes ;;
      --force)  FORCE=yes ;;
      --system) SYSTEM=yes ;;
      *)        _usage "unknown option for 'config': ${OPT}" ;;
    esac
  done
  # 決定 #5: オプションの整合を platform チェックより先に見る（テスト容易性）
  [[ -n "$SYSTEM" && -z "$INIT" ]] && _usage "$(_err_system_needs_init)"
  if [[ -n "$INIT" ]]; then
    TARGET=$(_config_init_target "$SYSTEM")
    _config_init "$TARGET" "$FORCE"
    return 0
  fi
  ... 以降は既存のまま（_config_find / _config_file_list / パス列挙）
}
```

> `__show_warn` が `_config_init_target` の**中**で走る点に注意。`__show_warn` は stderr に書くため、`TARGET=$(...)` のコマンド置換には混入しない。

出力例:

```console
$ sudo pfwd config --init --system
Created: /etc/port-forwarder/config.yaml
Edit the file and run 'pfwd test' to validate.
（Note: 行は出ない ─ /etc は _config_find の探索候補。決定 #1）

$ pfwd config --init --system                    # sudo 忘れ（決定 #11）
error: cannot write the config file: /etc/port-forwarder/config.yaml. Creating a file there needs write permission — rerun with sudo.
（終了コード 1。bash の 'Permission denied' は出ない）

$ pfwd -c ~/my.yaml config --init --system       # 決定 #2
[ WARN ] --system is ignored because --config was given
Created: /home/komori/my.yaml
Edit the file and run 'pfwd test' to validate.
Note: this path is not searched automatically. Run 'pfwd --config /home/komori/my.yaml <subcommand>'.

$ pfwd config --init --system                    # macOS（決定 #4）
error: --system is for Linux (systemd) only ... (uname: Darwin)
（終了コード 1）

$ pfwd config --system                           # 決定 #5
error: '--system' requires '--init' ...
usage: pfwd <subcommand> [options] [entry...]
...
（終了コード 2）
```

### 5. `pfwd` ─ `_config_init`（956 行）の書き込み失敗検知

決定 #11。判定の順番（ディレクトリ → 既存ファイル → `mkdir`）は変えない。

```bash
  DIR=$(dirname "$PATH_")
  if [[ ! -d "$DIR" ]] && ! mkdir -p "$DIR" 2>/dev/null; then
    _error_exit "$_EXIT_ERROR" "$(_err_config_mkdir "$DIR")"
  fi
  # 2>/dev/null must come BEFORE > "$PATH_", or bash's own redirection error leaks
  if ! cat 2>/dev/null > "$PATH_" <<'PFWD_CONFIG_TEMPLATE'
... テンプレート本文は 1 文字も変えない ...
PFWD_CONFIG_TEMPLATE
  then
    _error_exit "$_EXIT_ERROR" "$(_err_config_not_writable "$PATH_")"
  fi
  chmod 600 "$PATH_" 2>/dev/null
  ... 以降 Created: / Note: は既存のまま
```

### 6. `pfwd` ─ `_cmd_install_service`（2721 行）と main dispatch（2976 行）

決定 #6 / #7 / #9。**`_config_setup` を dispatch から `_cmd_install_service` の中へ移す。** `--system` はオプション走査が終わるまで判明しないため、現在の順序（dispatch で `_config_setup` → `_cmd_install_service`）では固定パスに切り替えられない。

main dispatch:

```bash
  install-service)
    _check_prerequisites
    _cmd_install_service ;;        # _config_setup はコマンド側で呼ぶ
```

`_cmd_install_service`（Darwin ガードとオプション走査は既存のまま）:

```bash
  ... オプション走査ループ（既存） ...

  # 決定 #6 / #9: --system は /etc の設定だけを見る
  if [[ "$SCOPE" == 'system' && -z "$_OPT_CONFIG" ]]; then
    _require_linux                                            # 決定 #4
    [[ -f "$_SYSTEM_CONFIG" ]] \
      || _error_exit "$_EXIT_CONFIG" "$(_err_no_system_config "$_SYSTEM_CONFIG")"
    _OPT_CONFIG=$_SYSTEM_CONFIG    # → _config_find が固定 / ExecStart に --config が入る
  fi
  _config_setup                                               # 決定 #7

  EXEC="$(_self_path) "
  [[ -n "$_OPT_CONFIG" ]] && EXEC="${EXEC}--config ${_CONFIG_FILE} "   # 既存のまま（決定 #8）
  EXEC="${EXEC}daemon"
  ... 以降 UNIT_DIR / _service_unit_text / systemctl は既存のまま
```

`-f` の存在確認を `_config_setup` より先に置くのは、`_config_find` が出す `_err_no_config`（`--system` なしの手順を案内する）に先回りするため（決定 #9）。

出力例:

```console
$ sudo pfwd install-service --system --run-as komori
error: system config file not found: /etc/port-forwarder/config.yaml. Run 'sudo pfwd config --init --system' to create it.
（終了コード 3）

$ sudo pfwd install-service --system --run-as komori
Generated: /etc/systemd/system/port-forwarder.service
Run the following to enable:
  systemctl daemon-reload
  systemctl enable --now port-forwarder
```

生成される unit の差分（決定 #8）:

```diff
 [Service]
 Type=simple
-ExecStart=/usr/local/bin/pfwd daemon
+ExecStart=/usr/local/bin/pfwd --config /etc/port-forwarder/config.yaml daemon
 ExecReload=/bin/kill -HUP $MAINPID
```

`--user` の unit と `--system -c <PATH>` の unit は**変わらない**。

### 7. `pfwd` ─ ヘルプ（`_help_config` 2051 行 / `_help_install_service` 2069 行）

```text
usage: pfwd [-c <PATH>] config [--init [--system] [--force]]
...
options:
  --init        create a template config file
  --system      create it at /etc/port-forwarder/config.yaml (Linux only; needs root)
  --force       overwrite an existing file (with --init)

... (既存の段落) ...
--system and -c, --config are mutually exclusive; -c wins.
```

```text
usage: pfwd install-service [--user|--system] [--run-as USER] [--now]
...
options:
  --user        generate a user unit (default)
  --system      generate a system unit in /etc/systemd/system; the config must
                exist at /etc/port-forwarder/config.yaml and is pinned into
                ExecStart. Run 'pfwd config --init --system' first if it does not
  ...
```

`_show_usage`（1893 行）の common options は変更しない（サブコマンド固有オプションは載せていない）。

### 8. `test/test_config.bats` ─ テスト追加（コメントは日本語）

`helper.bash` がファイルスコープで source するため、テスト内で `_SYSTEM_CONFIG` を `BATS_TEST_TMPDIR` 配下へ差し替えられる（決定 #10）。これで **root なしで `--system` 経路の中身を検証できる**。

- `_config_init_target` に `--system` を渡すと `_SYSTEM_CONFIG` を返す（Linux のみ。他は `skip`）
- `_OPT_CONFIG` と `--system` の両方があると `_OPT_CONFIG` を返し、stderr に `--system is ignored` が出る（決定 #2。platform 非依存）
- `--system` 無しなら従来どおり `_config_user_path` を返す（**変わらないことの確認**）
- `_SYSTEM_CONFIG` を一時ディレクトリへ向けて `_config_init` を呼ぶと、`Created:` が出て `Note:` 行が**出ない**（決定 #1）
- 書き込めないパス（`chmod 500` したディレクトリ配下）へ `_config_init` を呼ぶと終了コード 1 と `cannot write the config file`、かつ出力に `Created:` が**含まれない**（決定 #11 / 現状不具合 (b)）

### 9. `test/test_cli.bats` ─ テスト追加（コメントは日本語）

- `pfwd config --system`（`--init` なし）→ 終了コード 2 と `requires '--init'`（決定 #5。platform 非依存）
- 非 Linux で `pfwd config --init --system` → 終了コード 1 と `Linux (systemd) only`（`[ "$(uname)" = 'Linux' ] && skip`）
- `_service_unit_text system komori '/usr/local/bin/pfwd --config /etc/port-forwarder/config.yaml daemon'` の `ExecStart` に `--config` が入る（決定 #8。既存 `test/test_cli.bats:258` と同じ形）
- 既存の `service: user unit の内容が DESIGN 5.10 に一致する` が**そのまま通る**こと（`--user` の unit は変えない）

## 触らないもの

| 触らないもの | 理由 |
| --- | --- |
| `_config_find` の探索順と `conf.d` マージ（SPECS 4.1） | `--system` は「どこに書くか / どれを前提にするか」の話。読み込み仕様を変えると既存ユーザーの設定解決が変わる |
| `_parse_args`（`pfwd:2834`） | `--system` は既に `_SUBCMD_OPTS` に収集される。パーサに触る理由が無い |
| 設定テンプレート本文（`_config_init` の heredoc） | 作成先の話と無関係。1 文字も変えない |
| `_service_unit_text` の本文（`Restart` / `KillMode` / `WantedBy` など） | `ExecStart` に渡す `EXEC` 文字列だけが変わる。unit のテンプレート自体は SPECS 9.1 のまま |
| `install-service --user` / `uninstall-service` の挙動 | 要求は `--system` のみ。`--user` の `ExecStart` も `UNIT_DIR` も変えない |
| `_setup_runtime_dir` の判定条件（DESIGN 3.3） | リテラルを定数に差し替えるだけ。EUID 0 + `/etc/port-forwarder/` 配下という条件は維持（決定 #13） |
| `install-service` / `uninstall-service` の既存 macOS ガード | 決定 #12。条件を「Linux 以外」に広げると `--user` の挙動が要求の外で変わる |
| `--run-as` のユーザー存在チェックや root 実行警告 | 現状の警告のまま。要求の範囲外 |
| `EUID` による事前の root 判定 | 決定 #11。`/etc/port-forwarder` が書ける運用を塞がない |
| `install.sh` | bash 3.2 制約下の別系統。今回の変更と無関係 |
| `PFWD_SYSTEM_CONFIG` のようなテスト用環境変数の新設 | `helper.bash` のファイルスコープ source で `_SYSTEM_CONFIG` を差し替えられるため不要。本番コードにテスト用の抜け穴を作らない |

## フェーズ

2 つのサブコマンドに跨り、両者が定数と `_require_linux` を共有するため 2 フェーズに割る。P1 だけで実運用上意味のある単位（システム設定を作れる）になる。

| | 内容 | これだけで何が変わるか |
| --- | --- | --- |
| **P1** | 変更点 1（定数化）/ 2（`_err_*`）/ 3（`_require_linux`）/ 4（`_cmd_config` と `_config_init_target`）/ 5（書き込み失敗検知）/ 7 の `_help_config` / 8（`test_config.bats`）と 9 のうち `config` 分 | `sudo pfwd config --init --system` で `/etc/port-forwarder/config.yaml` が作れる。`sudo` を忘れたときに嘘の `Created:` ではなくエラーが出る。`-c` 併用時は warn が出る。非 Linux ではエラーで終わる |
| **P2** | 変更点 6（`_cmd_install_service` + main dispatch）/ 7 の `_help_install_service` / 9 のうち `install-service` 分 | `sudo pfwd install-service --system` が `/etc/port-forwarder/config.yaml` だけを見るようになり、無ければ P1 のコマンドを案内する。生成される system unit の `ExecStart` に `--config /etc/port-forwarder/config.yaml` が入り、`--run-as` したユーザーの個人設定を拾わなくなる |
| **P3（今回やらない）** | `docs/SPECS_ja.md` → `docs/SPECS.md`、`README_ja.md` → `README.md`、`docs/DESIGN_ja.md` への反映 | 文書のみ。**実装完了後**に行う（`feature-design` の範囲外。内容は「実装後に更新する文書」節） |

各フェーズの終わりに `task lint`（shellcheck 0 件）と `task check`（`bash -n`）、`task test` を通す。

## 検証

### 自動

| 対象 | 確認すること |
| --- | --- |
| `test/test_config.bats:139-159`（既存） | `--config <PATH> config --init` の成功・二重生成エラー（1）・`--force` 成功・生成物が `list` で読めることが**すべて従来どおり**。`Created:` / `Note:` 行の文面も変わらない |
| `test/test_cli.bats:258`（既存 user unit） | `--user` の unit 本文が**1 バイトも変わらない**（`ExecStart=/usr/local/bin/pfwd daemon` のまま） |
| `test/test_cli.bats:276`（既存 macOS ガード） | macOS で `install-service` / `uninstall-service` が終了コード 1 のまま |
| 追加テスト（`test_config.bats`） | `_config_init_target` の 3 分岐（`-c` 優先 + warn / `--system` / 既定）。`_SYSTEM_CONFIG` を一時ディレクトリへ差し替えた `_config_init` で `Note:` 行が出ないこと。書き込み不可パスで終了コード 1 かつ `Created:` が出ないこと |
| 追加テスト（`test_cli.bats`） | `config --system`（`--init` なし）→ 終了コード 2。非 Linux で `config --init --system` → 終了コード 1。system unit の `ExecStart` に `--config` が入ること |
| `bats test/` 全体 | 1 本も落ちないこと。特に `test_state.bats` / `test_statemachine.bats`（`_setup_runtime_dir` の定数差し替えの影響確認） |
| `task lint`（shellcheck） | 0 件。suppress を増やさない |
| `task check` | `bash -n pfwd` と `/bin/bash -n install.sh`（`install.sh` は無変更だが確認は通す） |

### 手動

Linux 機で上から順に実行する（`/etc/port-forwarder` が無い状態から始める）。

1. `./pfwd config --init --system` → `error: cannot write the config file: /etc/port-forwarder/config.yaml ... rerun with sudo.`、`echo $?` が 1
2. `sudo ./pfwd config --init --system` → `Created: /etc/port-forwarder/config.yaml` と `Edit the file...` の **2 行だけ**。`ls -l` が `-rw-------`
3. `sudo ./pfwd config --init --system` をもう一度 → `error: config file already exists: ... Use --force to overwrite it.`、終了コード 1（既存挙動が効いていること）
4. `./pfwd -c "$HOME/my.yaml" config --init --system` → `[ WARN ] --system is ignored because --config was given` の後に `Created: $HOME/my.yaml` と `Note:` 行
5. `./pfwd config --system` → `error: '--system' requires '--init' ...` + usage、終了コード 2
6. `sudo ./pfwd install-service --system --run-as "$USER"` → `Generated: /etc/systemd/system/port-forwarder.service`。`grep ExecStart` が `--config /etc/port-forwarder/config.yaml daemon` を含む
7. `sudo rm -f /etc/port-forwarder/config.yaml; sudo ./pfwd install-service --system --run-as "$USER"` → `error: system config file not found: ... Run 'sudo pfwd config --init --system' to create it.`、終了コード 3。**unit ファイルが作られていない**こと
8. `./pfwd install-service --user` → `Generated: ~/.config/systemd/user/port-forwarder.service`。`grep ExecStart` が `--config` を**含まない**（従来どおり）
9. `./pfwd -c "$HOME/my.yaml" install-service --system` → `ExecStart` が `--config $HOME/my.yaml daemon`（`-c` 優先が `install-service` でも効く）
10. `./pfwd help config` / `./pfwd help install-service` に `--system` の説明が出る

macOS 機で:

11. `./pfwd config --init --system` → `error: --system is for Linux (systemd) only ... (uname: Darwin)`、終了コード 1。**`~/.config/port-forwarder/config.yaml` が作られていない**こと
12. `./pfwd config --init` → 従来どおり `Created: ~/.config/port-forwarder/config.yaml`（`--system` を足したことで既定経路が壊れていないこと）

### 見えないものの確認

- 手順 1 の出力に `Created:`、および bash 自身の `Permission denied` が**含まれない**こと（決定 #11）
- 手順 7 で `/etc/systemd/system/port-forwarder.service` が**生成されていない**こと（設定チェックが unit 書き出しより先に走っている証拠）
- 手順 8 の unit に `--config` の文字列が**含まれない**こと（決定 #8 が `--user` に漏れていない）
- 手順 11 でファイルが**作られていない**こと（platform チェックが `_config_init` より先に走っている）
- `--system` を付けない `pfwd config --init` / `pfwd install-service --user` の出力に `WARN` 行が**出ない**こと

## 見送った案

| 案 | 見送った理由 |
| --- | --- |
| `--system` を `-c` より優先する | 要求が「`-c` 指定時、`--system` は無視される」と明示している |
| `-c` と `--system` の併用を usage エラーにする | 「無視される」という要求と食い違う。`pfwd -c ... config --init --system` を含むスクリプトが壊れる |
| `-c` 併用時も無視を黙って行う | `--system` と書いたのに `/etc` に作られないことに気づけない（決定 #2） |
| `install-service --system` を存在確認だけにする | 壊れた設定で unit を作り `systemctl enable --now` まで走らせてしまう。現状の `install-service` は既に完全検証を通しており、弱める理由が無い（決定 #7） |
| `ExecStart` に `--config` を埋め込まない | `--run-as USER` の system unit は `User=USER` で動くため、SPECS 4.1 の探索順で `USER` の個人設定が**先に**当たる。install 時に検証したファイルと daemon が読むファイルがずれる（決定 #8） |
| dispatch で `_SUBCMD_OPTS` を先読みして `_OPT_CONFIG` を決める | main dispatch にサブコマンド固有オプションの知識が漏れる。`--system` の解釈が `_cmd_install_service` と 2 箇所に散る |
| `_config_setup` に「system モード」引数を足す | `_config_setup` は全サブコマンドの共通入口。`_OPT_CONFIG` への代入 1 行（決定 #6）で足りるのに、共通経路に分岐を増やす |
| `_config_init` に `--system` フラグを渡す | `Created:` / `Note:` / 既存ファイル判定がフラグごとに分岐し、既存の 4 経路のテストが増える。作成先はパス 1 本に畳める（決定 #1） |
| `EUID != 0` を事前チェックして `--system` を弾く | `/etc/port-forwarder` にグループ書き込み権限を与えた運用を塞ぐ。実際の失敗を検知して案内すれば同じ情報が出る（決定 #11） |
| `install-service` / `uninstall-service` の macOS ガードを「Linux 以外」に広げる | 要求の範囲外で `--user` の挙動が変わる。`--system` は `_require_linux` で必ず弾かれるので今回の目的には不要（決定 #12） |
| `config --system`（`--init` なし）でシステム設定のパスを表示する | 要求に無い振る舞いの追加。`pfwd config` は「使用中の設定パスを表示する」コマンドであり、使っていないパスを表示する意味が薄い（決定 #5） |
| `PFWD_SYSTEM_CONFIG` 環境変数でテストからパスを差し替える | `helper.bash` のファイルスコープ source で `_SYSTEM_CONFIG` を直接差し替えられる。本番コードにテスト専用の設定経路を増やさない |
| `/etc/port-forwarder/config.yaml` のリテラルをそのまま増やす | `--system` で参照が 3→6 箇所になり、テストから差し替えられず root 必須のテストしか書けなくなる（決定 #10） |

## 実装後に更新する文書

**この設計の時点では反映しない。** 日本語版を先に更新し、その後で英訳に反映する（`CLAUDE.md`「Handling Documentation」）。

| 文書 | 追記する内容 |
| --- | --- |
| `docs/SPECS_ja.md` 4.5 雛形生成（258 行付近） | **新規記述**: `--system` で `/etc/port-forwarder/config.yaml` に作成できること（Linux 限定、root 必要）、`Note:` 行が出ないこと、`-c` 併用時は `-c` が勝ち warn が出ること、`--init` なしの `--system` は終了コード 2、非 Linux は終了コード 1。console 例を 2 つ追加 |
| `docs/SPECS_ja.md` 9.1 Linux（systemd）（513 行付近） | **既存記述の改訂**: `--system` の項に「設定ファイルは `/etc/port-forwarder/config.yaml` にある前提で存在確認する。無ければ終了コード 3 で `config --init --system` を案内する」「生成される unit の `ExecStart` に `--config /etc/port-forwarder/config.yaml` が入る」を追記。`ExecStart=/usr/local/bin/pfwd daemon` の記述を `--user` / `--system` で書き分ける |
| `docs/SPECS_ja.md` 3.2 共通オプション（126 行） | `-c, --config <PATH>` の説明に「`config --init --system` より優先される」を追記 |
| `docs/SPECS_ja.md` 8 章 システム全体運用（489 行付近） | セットアップ手順（`config --init --system` → 編集 → `install-service --system`）を 3 行で追記 |
| `docs/SPECS_ja.md` 10 章 エラーメッセージ方針（表, 536 行付近） | 「`--system` が非 Linux」「システム設定ファイル未検出」「設定ファイルが書き込めない」「`--system` に `--init` が無い」の 4 行を追加 |
| `docs/SPECS.md` | 上記 5 箇所の英訳（4.5 / 9.1 / 3.2 / 8 章 / 10 章。対応行は 156 / 542 付近ほか） |
| `README_ja.md` クイックスタート（101 行付近）とサブコマンド表（252 行付近） | システム常駐のセットアップ例（`sudo pfwd config --init --system` → `sudo pfwd install-service --system --run-as <user> --now`）を追加し、表の `config` 行に `--system` を添える |
| `README.md` | 上記の英訳（102 行 / 253 行付近） |
| `docs/DESIGN_ja.md` 3.3 実行時ディレクトリ（167 行） | システム判定のパス参照が定数 `_SYSTEM_CONFIG_DIR` になったことを 1 行追記（条件自体は不変） |
| `docs/DESIGN_ja.md` 1.2 内部定数 | `_SYSTEM_CONFIG_DIR` / `_SYSTEM_CONFIG` を定数表に追加（決定 #10） |
| `docs/DESIGN_ja.md` 5 章 関数表 `_cmd_config`（696 行） | `--system` の扱い（`-c` 優先 + warn / `--init` 必須 / Linux 限定）と、作成先決定を `_config_init_target` に切り出したことを追記 |
| `docs/DESIGN_ja.md` 5 章 関数表 `_cmd_install_service`（694 行） | `--system` 時に `/etc/port-forwarder/config.yaml` の存在を確認して `_OPT_CONFIG` に固定すること、`_config_setup` を dispatch からこの関数へ移したことを追記 |
| `docs/DESIGN_ja.md` 5 章 関数表 | `_require_linux` / `_config_init_target` の 2 行を新規追加 |
| `docs/DESIGN_ja.md` 7.3 エラーメッセージ一覧 | `_err_system_not_linux` / `_err_system_needs_init` / `_err_no_system_config` / `_err_config_not_writable` / `_err_config_mkdir` の 5 行を追加 |
| `docs/DESIGN_ja.md` main dispatch の説明箇所 | `install-service` が `_config_setup` を dispatch で呼ばなくなったことを追記 |
