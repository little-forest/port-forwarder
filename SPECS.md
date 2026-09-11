# port-forwarder 外部設計書

本書は [IDEA.md](../IDEA.md) を元に、**ユーザーから見た振る舞い**（CLI・設定ファイル・出力・運用手順）に絞って定義する。
内部実装（関数分割、プロセス制御の実現方式など）は本書の対象外とし、別途内部設計書で定義する。

- 対象バージョン: v1.0（初版）
- 作成日: 2026-09-08

---

## 1. 概要

### 1.1 目的

任意のリモートホストへの SSH ポートフォワーディングを常時維持するサービス。
一度設定すれば、接続断が発生しても自動的に再接続し、ローカルポートが常に利用可能な状態を保つ。

### 1.2 提供価値

| 課題 | 本ツールによる解決 |
| --- | --- |
| `ssh -L` を手動で張り直すのが面倒 | 死活監視して自動再接続 |
| 複数の踏み台・ポートを毎回打ち込むのが煩雑 | 設定ファイルに名前を付けて定義、名前で操作 |
| 今どれが繋がっているか分からない | `status` で接続状況を一覧表示 |
| 端末を閉じると切れる | デーモン化 / systemd サービス登録 |

### 1.3 スコープ

| 項目 | 対応 |
| --- | --- |
| フォワード種別 | ローカルフォワード（`ssh -L` 相当）のみ |
| 認証方式 | SSH 公開鍵認証のみ（パスワード認証・キーボードインタラクティブは非対応） |
| 対応 OS | RedHat 系 Linux（RHEL / Rocky / AlmaLinux / Fedora）、macOS |
| 実装 | bash スクリプト |
| サービス登録 | Linux: systemd（user / system 両方）のみ。macOS では `pfwd up` による手動常駐のみ対応し、launchd 登録は行わない |

> リモートフォワード（`-R`）・ダイナミックフォワード（`-D`）は v1.0 のスコープ外。将来拡張として 12 章に記載。

### 1.4 用語

| 用語 | 意味 |
| --- | --- |
| エントリ | 設定ファイル内で定義された 1 本のポートフォワード定義。一意な「名前」を持つ |
| セッション | エントリに対応して実際に起動している SSH プロセス |
| デーモン | 全エントリを監視・維持する常駐プロセス |
| 死活監視 | セッションが実際に利用可能かを定期的に確認する処理 |

---

## 2. 前提条件

### 2.1 依存コマンド

| コマンド | 用途 | 入手 |
| --- | --- | --- |
| `bash` (4.2 以上) | 実行環境 | Linux: 標準 / macOS: `brew install bash`（設定・状態の保持に連想配列と `declare -g` を使うため 4.2 未満では動作しない。起動時に判定し、満たさなければ終了コード 7 で終了する） |
| `ssh` (OpenSSH 7.4+) | フォワーディング本体 | 両 OS 標準 |
| `yq` (mikefarah/yq v4 系) | 設定ファイル（YAML）の解析 | 導入済みかつ PATH が通っていることを前提とする（導入手順は本設計のスコープ外） |
| `nc` または `bash /dev/tcp` | ローカルポートの疎通確認 | 標準（`nc` が無い場合は `/dev/tcp` にフォールバック） |
| `awk` / `sed` / `grep` | 出力整形 | 両 OS 標準 |
| `date` / `sleep` / `kill` | 監視ループ | 両 OS 標準 |

> `ss`・`lsof` などの追加コマンドには依存しない。存在すれば診断情報の精度向上に利用する（任意）。

`yq` は **mikefarah/yq v4 以上**（Go 実装）を前提とする。導入・PATH 設定は利用者の責任範囲とし、本ツールでは導入手順の案内やバージョンの自動判定は行わない。
未導入の場合は他の依存コマンドと同様、コマンドが見つからない旨のエラーで終了する（終了コード 7）。

### 2.2 SSH 側の前提

- 接続先ごとに公開鍵認証が設定済みであること。
- パスフレーズ付き鍵を使う場合は `ssh-agent` が利用可能であること（後述 9.2）。
- ホスト鍵が `known_hosts` に登録済みであること。未登録ホストへは**接続を試みず失敗**とし、ユーザーに登録を促す（自動 `StrictHostKeyChecking=no` はしない）。

---

## 3. コマンド体系

コマンド名は `pfwd` とする。

```
pfwd <サブコマンド> [オプション] [エントリ名...]
```

### 3.1 サブコマンド一覧

| サブコマンド | 説明 |
| --- | --- |
| `start [名前...]` | 指定エントリのフォワードを開始する。省略時は `enabled` な全エントリ |
| `stop [名前...]` | 指定エントリのフォワードを停止する。省略時は全エントリ |
| `restart [名前...]` | 停止してから開始する |
| `status [名前...]` | 接続状況を一覧表示する（既定サブコマンド） |
| `list` | 設定ファイルに定義されたエントリの一覧を表示する（接続状態は見ない） |
| `daemon` | 死活監視デーモンをフォアグラウンドで起動する（systemd から利用） |
| `up` | デーモンをバックグラウンドで起動する |
| `down` | デーモンを停止する（配下の全セッションも停止） |
| `reload` | 設定ファイルを再読み込みし、差分のみ反映する |
| `logs [名前]` | ログを表示する。`-f` で追従 |
| `test [名前...]` | 設定の妥当性検証と接続テスト（フォワードは張らない） |
| `install-service` | systemd unit を生成・登録する（Linux のみ） |
| `uninstall-service` | systemd unit の登録を解除する（Linux のみ） |
| `config` | 設定ファイルのパス表示・雛形生成 |
| `version` | バージョン表示 |
| `help [サブコマンド]` | ヘルプ表示 |

引数なしで `pfwd` を実行した場合は `pfwd status` と同じ動作とする。

### 3.2 共通オプション

| オプション | 説明 |
| --- | --- |
| `-c, --config <PATH>` | 使用する設定ファイルを指定する |
| `-v, --verbose` | 詳細ログを標準エラー出力に出す（`-vv` でさらに詳細） |
| `-q, --quiet` | エラー以外の出力を抑制する |
| `--no-color` | 色付けを無効化する（非 TTY 時は自動で無効） |
| `-h, --help` | ヘルプ表示 |
| `-V, --version` | バージョン表示 |

---

## 4. 設定ファイル

### 4.1 配置場所

以下の順に探索し、最初に見つかったものを使用する。

1. `--config` で指定されたパス
2. `$XDG_CONFIG_HOME/port-forwarder/config.yaml`（未設定時は `~/.config/port-forwarder/config.yaml`）
3. `/etc/port-forwarder/config.yaml`（システム全体設定）

`~/.config/port-forwarder/conf.d/*.yaml` が存在する場合、メイン設定の後に名前順で読み込みマージする。
マージ規則は「後勝ち」で、`global` はキー単位、`entries` はエントリ単位で上書きする。拡張子は `.yaml` / `.yml` の両方を受け付ける。

### 4.2 形式

**YAML 形式**を採用する。解析には `yq` を使用する。

トップレベルは `global`（省略可）と `entries`（必須）の 2 つ。`entries` はエントリ名をキーとしたマップとし、キーの重複は YAML の仕様上検出できるため名前の一意性が保証される。

```yaml
# グローバル設定（省略可。省略時は既定値）
global:
  check_interval: 30          # 死活監視間隔（秒）
  connect_timeout: 10         # SSH 接続タイムアウト（秒）
  retry_initial: 5            # 再接続の初回待ち時間（秒）
  retry_max: 300              # 再接続待ち時間の上限（秒）
  log_file: ~/.local/state/port-forwarder/port-forwarder.log  # 未指定なら標準出力

# エントリ定義。キーがエントリ名（一意）
entries:
  db-prod:
    description: 本番DBへの参照用トンネル
    host: bastion.example.com     # 必須: SSH 接続先ホスト
    user: komori                  # 任意: 既定は $USER / ~/.ssh/config の設定
    port: 22                      # 任意: SSH ポート。既定 22
    identity: ~/.ssh/id_ed25519   # 任意: 秘密鍵
    local_port: 15432             # 必須: ローカル待ち受けポート
    remote_host: db.internal      # 任意: 既定 localhost（踏み台から見たホスト）
    remote_port: 5432             # 必須: リモート側ポート
    bind_address: 127.0.0.1       # 任意: 既定 127.0.0.1
    enabled: true                 # 任意: 既定 true。false なら自動起動対象外
    check_mode: remote            # 任意: process | tcp | remote。既定 remote

  redis-stg:
    host: stg-bastion.example.com
    user: komori
    local_port: 16379
    remote_host: redis.internal
    remote_port: 6379

  metrics:
    host: bastion.example.com
    local_port: 19090
    remote_host: prom.internal
    remote_port: 9090
    ssh_options:                  # 追加の ssh -o 指定はリストで記述する
      - ExitOnForwardFailure=yes
      - Compression=yes
```

- 値の型は YAML に従う（ポート番号は数値、`enabled` は真偽値）。文字列としてクォートしても受け付ける。
- `ExitOnForwardFailure=yes` は**常に既定で付与される**ため、上の `metrics` の例のように `ssh_options` へ明示する必要はない。`ssh_options` の指定は既定値の後に並ぶため、既定を上書きすることもできる。
- パス値の先頭 `~` は実行ユーザーのホームディレクトリに展開する。
- エントリ表示順は YAML の記述順を維持する。

### 4.3 パラメータ仕様

#### `[global]` セクション

| キー | 型 | 既定値 | 説明 |
| --- | --- | --- | --- |
| `check_interval` | 整数(秒) | `30` | 死活監視の実行間隔。最小 5 |
| `connect_timeout` | 整数(秒) | `10` | SSH 接続確立のタイムアウト |
| `retry_initial` | 整数(秒) | `5` | 再接続失敗時の初回待機時間 |
| `retry_max` | 整数(秒) | `300` | 指数バックオフの上限待機時間 |
| `retry_limit` | 整数 | `0` | 連続失敗の上限回数。`0` は無制限 |
| `server_alive_interval` | 整数(秒) | `15` | SSH の keepalive 間隔 |
| `server_alive_count_max` | 整数 | `3` | keepalive 応答なし許容回数 |
| `log_file` | パス | （未指定） | ログ出力先。**未指定時は標準出力に出力する** |

死活監視の TCP プローブに使う待ち時間は内部定数（接続タイムアウト 3 秒 / `remote` 判定の待機 1.0 秒）とし、v1.0 では設定できない。将来 `global.check_timeout` として公開する余地を残す。

#### エントリセクション

| キー | 必須 | 既定値 | 説明 |
| --- | --- | --- | --- |
| `host` | ✔ | - | SSH 接続先（踏み台）ホスト名 / IP |
| `local_port` | ✔ | - | ローカル待ち受けポート（1-65535） |
| `remote_port` | ✔ | - | 転送先ポート |
| `user` | | `$USER` | SSH ユーザー名 |
| `port` | | `22` | SSH ポート |
| `identity` | | - | 秘密鍵パス。未指定時は ssh の既定 / `~/.ssh/config` に従う |
| `remote_host` | | `localhost` | 踏み台から見た転送先ホスト |
| `bind_address` | | `127.0.0.1` | ローカル待ち受けアドレス。`0.0.0.0` 指定時は警告を出す |
| `description` | | - | 一覧表示に出る説明文 |
| `enabled` | | `true` | `false` なら `start`（名前省略時）の対象外 |
| `check_mode` | | `remote` | 死活監視の方式（5.2 参照） |
| `check_interval` | | global 値 | エントリ個別の監視間隔 |
| `ssh_options` | | - | 追加の `ssh -o` 指定。文字列のリストで記述する |

### 4.4 命名・検証ルール

エントリ名は `[A-Za-z0-9._-]{1,32}`。

読み込み時に以下を検証し、1 つでも違反があれば**該当エントリのみ無効**として警告し、他のエントリは処理を継続する。

- 必須キーの欠落
- ポート番号が 1-65535 の整数でない
- `local_port` の重複（マージ後の全エントリ間）
- 未知のキー名（警告のみ、動作は継続）
- 指定された `identity` ファイルが存在しない
- 指定された `identity` ファイルの権限が他ユーザーに開いている（`ssh` 自身が拒否するため事前に弾く）
- `bind_address` が `0.0.0.0` / `::`（警告のみ、動作は継続）

以下の場合は設定全体のエラーとして即座に終了する（終了コード 3）。

- YAML として構文解析できない（`yq` のエラー内容を行番号付きで提示する）
- トップレベルが `entries` を持たない、または `entries` がマップでない
- `entries` が空

### 4.5 雛形生成

```console
$ pfwd config --init
Created: /home/komori/.config/port-forwarder/config.yaml
Edit the file and run 'pfwd test' to validate.
```

既にファイルが存在する場合は上書きせずエラーとする（`--force` で上書き可）。

---

## 5. 死活監視と再接続の振る舞い

### 5.1 状態遷移

ユーザーから見えるエントリの状態は以下の 6 種類。

| 状態 | 表示 | 意味 |
| --- | --- | --- |
| `connected` | 緑 | 正常にフォワード中。ローカルポートが利用可能 |
| `connecting` | 黄 | 接続確立中（初回接続または再接続の試行中） |
| `retrying` | 黄 | 接続に失敗し、バックオフ待機中 |
| `stopped` | 灰 | ユーザー操作で停止中 |
| `disabled` | 灰 | 設定で `enabled = false` |
| `failed` | 赤 | 再試行上限に達した、または設定不備で起動できない |

```
        start                 確立成功
stopped ─────> connecting ───────────> connected
   ^               │                       │
   │               │ 失敗                  │ 断検知
   │               v                       v
   └──── stop ── retrying <────────────────┘
                   │ retry_limit 到達
                   v
                 failed
```

### 5.2 監視方式（`check_mode`）

| 値 | 確認内容 | 用途 |
| --- | --- | --- |
| `process` | SSH プロセスが生存しているか | 最も軽量。ゾンビ状態は検知できない |
| `tcp` | ローカルポートが TCP 接続を受け付けるか | 軽量な確認。プロセス生存 + LISTEN 確認 |
| `remote`（既定） | ローカルポート経由で実際に転送先まで到達するか | 最も確実。踏み台から先が落ちた場合も検知 |

既定を `remote` としたのは、SSH プロセスが生きたままフォワードだけが機能しなくなる状態を確実に検知するためである。この方式では監視のたびに転送先へ TCP 接続を行うため、以下の点に留意する。

- 転送先サーバーに監視由来の接続ログが `check_interval` ごとに記録される。
- 接続確認はハンドシェイク成立の確認のみで、データは送信せず即座に切断する。
- 接続ログを増やしたくない、または接続コストを避けたいエントリでは `check_mode: tcp` を指定する。

### 5.3 再接続ポリシー

- 断を検知したら、まず既存 SSH プロセスを確実に終了させてから再接続する。
- 再接続の待機時間は指数バックオフ: `retry_initial` から始まり、失敗ごとに 2 倍、`retry_max` で頭打ち。
  例: `5s → 10s → 20s → 40s → 80s → 160s → 300s → 300s ...`
- 接続が **60 秒以上継続** したらバックオフをリセットし、次回の初回待ち時間を `retry_initial` に戻す。
- `retry_limit` に達したエントリは `failed` となり、自動再試行を停止する。復帰には `pfwd restart <名前>` が必要。
- ローカルポートが他プロセスに使用されている場合は再試行せず即 `failed` とし、使用中である旨をログに記録する。

### 5.4 デーモンの振る舞い

- `pfwd up` / `pfwd daemon` は全 `enabled` エントリを起動し、`check_interval` ごとに死活監視する。
- 二重起動は PID ファイルで防止し、既に起動中なら明示的にエラーを返す（終了コード 6）。
- デーモンが起動していない状態での `down` は、何もせず成功（終了コード 0）とする（冪等）。
- `SIGTERM` / `SIGINT` 受信時は、配下の全 SSH プロセスを終了させてから終了する（孤児プロセスを残さない）。
- `SIGHUP` 受信時は設定を再読み込みする（`pfwd reload` と同等）。

### 5.5 `reload` の差分反映

| 設定の変更内容 | 振る舞い |
| --- | --- |
| エントリ追加 | 追加分を起動する |
| エントリ削除 | 該当セッションを停止する |
| 接続パラメータ変更 | 該当エントリのみ再起動する |
| `enabled` を false に変更 | 該当セッションを停止し `disabled` にする |
| `description` のみ変更 | セッションは維持し、表示のみ更新する |
| `[global]` の変更 | 次回の監視サイクルから反映（既存セッションは維持） |

---

## 6. 出力仕様

### 6.1 `pfwd status`

```console
$ pfwd status
NAME        STATUS      LOCAL            REMOTE                       UPTIME    RETRY  DESCRIPTION
db-prod     connected   127.0.0.1:15432  db.internal:5432             2d 04:11      0  本番DBへの参照用トンネル
redis-stg   connected   127.0.0.1:16379  redis.internal:6379          05:22         0
metrics     retrying    127.0.0.1:19090  prom.internal:9090           -             3  次回試行まで 40s
legacy      disabled    127.0.0.1:18080  legacy.internal:80           -             -  移行済み
batch       failed      127.0.0.1:12222  batch.internal:22            -            10  ローカルポート使用中

5 entries: 2 connected, 1 retrying, 1 disabled, 1 failed
```

- 色付け: `connected` = 緑、`connecting` / `retrying` = 黄、`failed` = 赤、`stopped` / `disabled` = 灰。
- 非 TTY 出力時、`--no-color` 指定時は色を付けない。
- デーモンが起動していない場合は先頭に `daemon: not running` を表示し、各エントリは実プロセス状況から判定して表示する。
- 出力は上記の整形表のみとする。特定のエントリだけを見たい場合は `pfwd status <名前...>` のように引数で絞り込む。

### 6.2 `pfwd list`

設定内容のみを表示する（プロセス状態を見ないため高速）。

```console
$ pfwd list
NAME        ENABLED  SSH                          LOCAL            REMOTE
db-prod     yes      komori@bastion.example.com   127.0.0.1:15432  db.internal:5432
redis-stg   yes      komori@stg-bastion.exam...   127.0.0.1:16379  redis.internal:6379
legacy      no       komori@old-bastion.exam...   127.0.0.1:18080  legacy.internal:80
```

### 6.3 `pfwd start` / `stop` / `restart`

進捗を 1 エントリ 1 行で表示する。

```console
$ pfwd start db-prod redis-stg
[  OK  ] db-prod    connected (127.0.0.1:15432 -> db.internal:5432)
[  OK  ] redis-stg  connected (127.0.0.1:16379 -> redis.internal:6379)
2 started, 0 failed
```

失敗時:

```console
$ pfwd start metrics
[FAILED] metrics    ssh: connect to host bastion.example.com port 22: Connection timed out
0 started, 1 failed
```

- 既に接続済みのエントリへの `start` は成功扱い（冪等）とし、`[ SKIP ]  already connected` を表示する。
- 存在しないエントリ名を指定した場合はエラー終了する（終了コード 2）。
- `start` / `stop` / `restart` / `reload` は**デーモンが起動していることが前提**であり、未起動の場合は何もせず終了コード 5 で `pfwd up` を案内する。

### 6.4 `pfwd test`

フォワードを張らずに設定と接続性を検証する。

```console
$ pfwd test
Config: /home/komori/.config/port-forwarder/config.yaml

[  OK  ] db-prod    config valid, ssh reachable, local port free
[  OK  ] redis-stg  config valid, ssh reachable, local port free
[ WARN ] metrics    config valid, ssh reachable, local port 19090 already in use
[FAILED] broken     missing required key: entries.broken.remote_port

3 passed, 1 warning, 1 failed
```

集計行は `[  OK  ]` を passed、`[ WARN ]` を warning、`[FAILED]` を failed として数える（1 エントリはいずれか 1 つに数えられる）。

### 6.5 ログ

- 出力先は `log_file` に指定したパス。**未指定時は標準出力**に出力する。
- 形式: `YYYY-MM-DDTHH:MM:SS±ZZZZ [LEVEL] [エントリ名] メッセージ`
- 例:

```
2026-09-08T21:31:04+0900 [INFO ] [db-prod] connection established (pid=48213)
2026-09-08T22:03:47+0900 [WARN ] [metrics] health check failed (tcp 127.0.0.1:19090 refused)
2026-09-08T22:03:47+0900 [INFO ] [metrics] reconnecting in 5s (attempt 1)
2026-09-08T22:04:02+0900 [ERROR] [metrics] ssh exited with status 255: Connection timed out
```

- 出力レベルは `INFO` / `WARN` / `ERROR` の 3 種類を常に出力する。`-v` を付けて実行した場合のみ `DEBUG` を追加で出力する。
- ログのローテートは行わない。ファイル出力を使う場合のサイズ管理は `logrotate` 等の OS 標準の仕組みに委ねる。
- `pfwd logs -f` で追従表示。`pfwd logs <名前>` で該当エントリの行のみ抽出。`log_file` 未指定時はファイルが存在しないため、`journalctl` によるログ参照方法（macOS ではフォアグラウンド実行または `log_file` の設定）を案内して終了する（終了コード 0）。
- 標準出力に出している場合、systemd 配下では journald が収集するため `journalctl -u port-forwarder` で参照できる。

---

## 7. 終了コード

| コード | 意味 |
| --- | --- |
| `0` | 正常終了 |
| `1` | 一般的な実行時エラー |
| `2` | 引数・オプションの誤り、存在しないエントリ名 |
| `3` | 設定ファイルが見つからない / 解析に失敗した |
| `4` | 1 つ以上のエントリで接続に失敗した |
| `5` | デーモンが起動していない（`status` 以外の操作で必要な場合） |
| `6` | 既にデーモンが起動している（`up` の二重起動） |
| `7` | 依存コマンドが不足している |

`status` はエントリの状態に関わらず、コマンド自体が成功すれば `0` を返す。ただし `--exit-code` を付けた場合、`connected` 以外が 1 つでもあれば `4` を返す（監視スクリプト連携用）。`--exit-code` は `status` 専用のオプションであり、3.2 の共通オプションではない。

---

## 8. ファイル配置

### 8.1 ユーザー単位で実行する場合（既定）

| 種別 | パス |
| --- | --- |
| 実行ファイル | `~/.local/bin/pfwd` |
| 設定 | `~/.config/port-forwarder/config.yaml`, `~/.config/port-forwarder/conf.d/*.yaml` |
| ログ | `log_file` に指定したパス（未指定時は標準出力。推奨値 `~/.local/state/port-forwarder/port-forwarder.log`） |
| 実行時状態（PID・状態ファイル） | `${XDG_RUNTIME_DIR}/port-forwarder/`（`XDG_RUNTIME_DIR` 未設定時は `~/.local/state/port-forwarder/run/`） |
| SSH ControlPath | 上記実行時ディレクトリ配下 |

### 8.2 システム全体で実行する場合

| 種別 | パス |
| --- | --- |
| 実行ファイル | `/usr/local/bin/pfwd` |
| 設定 | `/etc/port-forwarder/config.yaml`, `/etc/port-forwarder/conf.d/*.yaml` |
| ログ | `log_file` に指定したパス（未指定時は標準出力。推奨値 `/var/log/port-forwarder/port-forwarder.log`） |
| 実行時状態 | `/run/port-forwarder/` |

macOS で `/run` が使えない場合は `/usr/local/var/run/port-forwarder/` を使用する。なお macOS ではサービス登録を行わないため、システム全体での常駐運用は Linux のみを想定する。

---

## 9. サービス登録

サービス登録は Linux（systemd）のみを対象とする。macOS では `pfwd up` でバックグラウンド起動し、必要に応じて利用者側で常駐手段を用意する。

### 9.1 Linux（systemd）

```console
$ pfwd install-service --user
Generated: /home/komori/.config/systemd/user/port-forwarder.service
Run the following to enable:
  systemctl --user daemon-reload
  systemctl --user enable --now port-forwarder
  loginctl enable-linger komori    # ログアウト後も動かす場合
```

- `--user`（既定）: ユーザー単位の systemd unit を生成する。SSH 鍵・`ssh-agent` の扱いが素直なため推奨。
- `--system`: システム単位の unit を `/etc/systemd/system/port-forwarder.service` に生成する。`--run-as <ユーザー名>` で実行ユーザーを指定する（root 実行は非推奨、警告を表示）。
- 生成される unit の振る舞い:
  - `ExecStart=/usr/local/bin/pfwd daemon`
  - `ExecReload=/bin/kill -HUP $MAINPID`
  - `Restart=on-failure`、`RestartSec=10`
  - `After=network-online.target`
- `pfwd install-service --now` を指定すると `daemon-reload` と `enable --now` まで自動実行する。

### 9.2 パスフレーズ付き鍵の扱い

- パスフレーズ付き鍵を使う場合、デーモンからは対話入力できないため、以下いずれかをユーザーに案内する。
  1. パスフレーズなしの専用鍵を用意する（推奨。`command=` 制限や `permitopen` と併用）。
  2. `ssh-agent` を先に起動し、`SSH_AUTH_SOCK` をサービスに引き渡す（systemd user unit では `Environment=` で指定する）。
- パスフレーズ入力が必要な状態で接続に失敗した場合、ログに「passphrase-protected key requires ssh-agent」と明示し、リトライループに入る前に `failed` とする。

---

## 10. エラーメッセージ方針

すべて「**何が起きたか / なぜか / どうすればよいか**」の 3 点を含める。

| 状況 | 表示例 |
| --- | --- |
| 設定ファイル未検出 | `error: config file not found. Run 'pfwd config --init' to create one at ~/.config/port-forwarder/config.yaml` |
| YAML 構文エラー | `error: failed to parse config.yaml: bad indentation of a mapping entry at line 23, column 5` |
| 必須キー欠落 | `error: [broken] missing required key 'remote_port' (entries.broken)` |
| ポート重複 | `error: local_port 15432 is used by both [db-prod] and [db-copy]` |
| ローカルポート使用中 | `error: [db-prod] local port 15432 is already in use by another process` |
| ホスト鍵未登録 | `error: [db-prod] host key for bastion.example.com is not in known_hosts. Run: ssh-keyscan -H bastion.example.com >> ~/.ssh/known_hosts` |
| 鍵ファイル権限不正 | `error: [db-prod] identity file ~/.ssh/id_ed25519 has too open permissions (0644). Run: chmod 600 ~/.ssh/id_ed25519` |
| 依存コマンド不足 | `error: required command 'yq' not found. Install it and make sure it is in your PATH.` |
| デーモン二重起動 | `error: daemon is already running (pid 48120). Use 'pfwd down' to stop it.` |
| 未知のエントリ名 | `error: no such entry 'db-pord'` |

---

## 11. 非機能要件（ユーザーから見えるもの）

| 項目 | 要件 |
| --- | --- |
| 起動時間 | `pfwd status` は 1 秒以内に結果を返す（エントリ 50 件まで） |
| 常駐時のリソース | 監視間隔 30 秒・エントリ 10 件で CPU 使用率は平常時ほぼ 0%、メモリはシェル + SSH プロセス分のみ |
| 断からの復旧時間 | 既定設定で最大 `check_interval + retry_initial`（= 35 秒）以内に再接続を開始する |
| 同時エントリ数 | 100 エントリまで動作を保証する |
| 安全性 | `bind_address` の既定は `127.0.0.1` とし、外部公開になる設定には警告を出す |
| 秘匿情報 | ログにパスワード・鍵の中身を出力しない。ホスト名・ユーザー名は出力する |
| 権限 | 設定ファイルが他ユーザーから書き込み可能な場合は警告を出す |
| 冪等性 | `start` / `stop` は現在の状態に関わらず同じ結果に収束する |

---

## 12. 将来拡張（v1.0 スコープ外）

- リモートフォワード（`-R`）、ダイナミックフォワード（`-D`, SOCKS）への対応
- エントリのグループ化・タグによる一括操作（`pfwd start @prod`）
- 接続断・復旧時の通知フック（任意コマンド実行、Slack 通知など）
- ネットワーク変更（Wi-Fi 切替・スリープ復帰）の検知による即時再接続
- 接続履歴・稼働率の統計表示（`pfwd stats`）
- シェル補完（bash / zsh）の提供
- 設定ファイルの暗号化された秘密情報参照

---

## 13. 決定事項

設計判断が分かれた点について、以下のとおり確定した（2026-09-08）。

| 項目 | 決定内容 |
| --- | --- |
| コマンド名 | `pfwd` とする |
| `yq` の入手方法 | 本設計のスコープ外。導入済みかつ PATH が通っている前提とする |
| デーモン方式 | 全エントリを一元管理するデーモン方式を採用する |
| 既定の監視方式 | `check_mode` の既定を `remote`（実疎通確認）とする |
| macOS の launchd 対応 | スコープに含めない。サービス登録は Linux（systemd）のみ |
