# port-forwarder (`pfwd`)

[English](README.md) | **日本語**

SSH のローカルポートフォワード（`ssh -L` 相当）を常時維持する単一ファイルの bash スクリプト。

転送定義を設定ファイルに名前付きで書いておくと、デーモンが `check_interval` ごとに死活監視し、
切れたら指数バックオフで自動的に張り直す。`pfwd status` で全エントリの接続状況を一覧できる。

```console
$ pfwd status
NAME        STATUS      LOCAL            REMOTE                       UPTIME    RETRY  DESCRIPTION
db-prod     connected   127.0.0.1:15432  db.internal:5432             2d 04:11      0  本番DBへの参照用トンネル
redis-stg   connected   127.0.0.1:16379  redis.internal:6379          05:22         0
metrics     retrying    127.0.0.1:19090  prom.internal:9090           -             3  次回試行まで 40s

3 entries: 2 connected, 1 retrying
```

## 動作要件

| コマンド | バージョン | 必須 | 備考 |
| --- | --- | --- | --- |
| `bash` | 4.2 以上 | ✔ | macOS 標準の bash 3.2 では動作しない（`brew install bash`）。満たさない場合は終了コード 7 |
| `ssh` | OpenSSH 7.4 以上 | ✔ | 両 OS 標準 |
| `yq` | mikefarah/yq 4.31 以上 **または** kislyuk/yq 2.14 以上 | ✔ | Go 実装・Python 実装のどちらでも動作する |
| `jq` | 1.5 以上 | | `yq` が kislyuk/yq（Python 実装）のときのみ必須 |
| `nc` | - | | 任意。無い場合は bash の `/dev/tcp` を使う |

対応 OS は RedHat 系 Linux（RHEL / Rocky / AlmaLinux / Fedora）と macOS。

SSH 側の前提は以下の 3 点。

- 接続先ごとに**公開鍵認証**が設定済みであること（パスワード認証・キーボードインタラクティブは非対応）。
- ホスト鍵が `known_hosts` に登録済みであること。`StrictHostKeyChecking=yes` 固定のため、未登録ホストへは接続を試みない。
- 鍵はパスフレーズなしのものを推奨。パスフレーズ付き鍵を使う場合は `ssh-agent` を起動し、`SSH_AUTH_SOCK` をデーモンに引き渡す。

## インストール

最新リリースの `pfwd` を 1 行で取得・配置する。

```console
$ curl -fsSL https://raw.githubusercontent.com/little-forest/port-forwarder/main/install.sh | bash
```

既定のインストール先は OS ごとに異なる。

| OS | 既定のインストール先 | sudo |
| --- | --- | --- |
| Linux | `/usr/local/bin` | 書き込めない場合のみ自動で `sudo` に切り替わる |
| macOS | `~/.local/bin` | 不要 |

macOS の既定 PATH に `~/.local/bin` は含まれないため、PATH 未登録なら追加方法を案内する。

インストーラは次の環境変数を見る。

| 環境変数 | 既定値 | 意味 |
| --- | --- | --- |
| `PFWD_INSTALL_DIR` | 上表の OS 別既定 | インストール先ディレクトリ |
| `PFWD_VERSION` | 最新リリースのタグ | 取得する ref。`main` を指定すると開発版が入る |
| `NO_COLOR` | - | 色付き出力を無効化する（<https://no-color.org/>） |

```console
$ curl -fsSL .../install.sh | PFWD_INSTALL_DIR=~/bin bash   # 配置先を変える
$ curl -fsSL .../install.sh | PFWD_VERSION=v1.0.0 bash      # バージョンを固定する
$ curl -fsSL .../install.sh | PFWD_VERSION=main bash        # 開発版を入れる
```

依存コマンド（`bash` 4.2 以上 / `ssh` / `yq`）が不足していても、警告を出すだけでインストール自体は成功する。

### 手動でインストールする

`pfwd` 1 ファイルをコピーするだけでよい。ビルドは不要。

```console
$ install -m 755 pfwd ~/.local/bin/pfwd              # ユーザー単位（推奨）
$ sudo install -m 755 pfwd /usr/local/bin/pfwd       # システム全体
```

macOS では依存コマンドを先に入れておく。

```console
$ brew install bash yq
```

### アンインストール

配置したファイルを消すだけでよい。

```console
$ rm -f ~/.local/bin/pfwd          # macOS の既定
$ sudo rm -f /usr/local/bin/pfwd   # Linux の既定
```

設定ファイル（`~/.config/port-forwarder/`）は残るので、不要なら併せて削除する。

## クイックスタート

### 1. 設定ファイルの雛形を作る

```console
$ pfwd config --init
Created: /home/komori/.config/port-forwarder/config.yaml
Edit the file and run 'pfwd test' to validate.
```

任意の場所に作りたいときは `-c, --config <PATH>` を `config` より前に付ける。ただしそのパスは
自動では探索されないため、以降の実行でも `-c` が必要になる。

```console
$ pfwd --config ~/work/pfwd.yaml config --init
Created: /home/komori/work/pfwd.yaml
Edit the file and run 'pfwd test' to validate.
Note: this path is not searched automatically. Run 'pfwd --config /home/komori/work/pfwd.yaml <subcommand>'.
```

### 2. 設定ファイルを編集する

雛形の `example` エントリは `enabled: false` になっている。自分の転送先に書き換えて `enabled: true` にする。

### 3. 検証する

フォワードは張らずに、設定の妥当性・SSH 到達性・ローカルポートの空きだけを確認する。

```console
$ pfwd test
Config: /home/komori/.config/port-forwarder/config.yaml

[  OK  ] db-prod    config valid, ssh reachable, local port free
[  OK  ] redis-stg  config valid, ssh reachable, local port free

2 passed, 0 warning, 0 failed
```

### 4. デーモンを起動する

`enabled: true` な全エントリのフォワードが張られ、以降は自動で維持される。

```console
$ pfwd up
daemon started (pid=48120)
```

### 5. 状況を確認する

```console
$ pfwd status
```

`pfwd` を引数なしで実行した場合も `pfwd status` と同じ動作になる。

### 6. 停止する

デーモンと配下の全 SSH セッションが終了する。

```console
$ pfwd down
```

> [!IMPORTANT]
> `start` / `stop` / `restart` / `reload` は**デーモンが起動していることが前提**である。
> 未起動で実行した場合は何もせず、終了コード 5 で `pfwd up` を案内する。

## 設定ファイル

以下の順に探索し、最初に見つかったものを使用する。

1. `--config` で指定したパス
2. `$XDG_CONFIG_HOME/port-forwarder/config.yaml`（未設定時は `~/.config/port-forwarder/config.yaml`）
3. `/etc/port-forwarder/config.yaml`

採用した設定ファイルと同じディレクトリに `conf.d/*.yaml`（`*.yml` も可）があれば、名前順に読み込んで後勝ちでマージする。

トップレベルは `global`（省略可）と `entries`（必須）の 2 つ。`entries` のキーがエントリ名になる。

```yaml
global:
  check_interval: 30          # 死活監視間隔（秒）。最小 5
  log_file: ~/.local/state/port-forwarder/port-forwarder.log   # 未指定なら標準出力

entries:
  db-prod:
    description: 本番DBへの参照用トンネル
    host: bastion.example.com     # 必須: SSH 接続先（踏み台）
    user: komori
    identity: ~/.ssh/id_ed25519
    local_port: 15432             # 必須: ローカル待ち受けポート
    remote_host: db.internal      # 踏み台から見た転送先。既定 localhost
    remote_port: 5432             # 必須: 転送先ポート

  redis-stg:
    host: stg-bastion.example.com
    user: komori
    local_port: 16379
    remote_host: redis.internal
    remote_port: 6379
    check_mode: tcp               # 転送先への監視接続を避けたい場合
```

### よく使うエントリのキー

| キー | 必須 | 既定値 | 説明 |
| --- | --- | --- | --- |
| `host` | ✔ | - | SSH 接続先（踏み台）ホスト |
| `local_port` | ✔ | - | ローカル待ち受けポート（1-65535） |
| `remote_port` | ✔ | - | 転送先ポート |
| `user` | | `$USER` | SSH ユーザー名 |
| `remote_host` | | `localhost` | 踏み台から見た転送先ホスト |
| `identity` | | - | 秘密鍵パス。未指定時は `~/.ssh/config` に従う |
| `bind_address` | | `127.0.0.1` | ローカル待ち受けアドレス |
| `enabled` | | `true` | `false` なら自動起動の対象外 |
| `check_mode` | | `remote` | 死活監視の方式（後述） |
| `description` | | - | 一覧表示に出る説明文 |

エントリ名に使える文字は `[A-Za-z0-9._-]` で、1〜32 文字。

### よく使う `global` のキー

| キー | 既定値 | 説明 |
| --- | --- | --- |
| `check_interval` | `30` | 死活監視の実行間隔（秒）。最小 5 |
| `connect_timeout` | `10` | SSH 接続確立のタイムアウト（秒） |
| `retry_initial` | `5` | 再接続の初回待機時間（秒） |
| `retry_max` | `300` | 指数バックオフの上限待機時間（秒） |
| `retry_limit` | `0` | 連続失敗の上限回数。`0` は無制限 |
| `log_file` | （未指定） | ログ出力先。**未指定時は標準出力** |

キーの全一覧は [docs/SPECS_ja.md](docs/SPECS_ja.md) の 4.3 節を参照。

### 死活監視の方式（`check_mode`）

| 値 | 確認内容 |
| --- | --- |
| `process` | SSH プロセスが生存しているか。最も軽量 |
| `tcp` | ローカルポートが TCP 接続を受け付けるか |
| `remote`（既定） | ローカルポート経由で実際に転送先まで到達するか。最も確実 |

既定の `remote` は SSH プロセスが生きたままフォワードだけが機能しない状態も検知できるが、
**`check_interval` ごとに転送先へ実際に TCP 接続する**ため、転送先に接続ログが残る。
これを避けたいエントリには `check_mode: tcp` を指定する。

## コマンド一覧

```
pfwd <サブコマンド> [オプション] [エントリ名...]
```

| サブコマンド | 説明 |
| --- | --- |
| `start [名前...]` | フォワードを開始する。名前省略時は `enabled` な全エントリ |
| `stop [名前...]` | フォワードを停止する。名前省略時は全エントリ |
| `restart [名前...]` | 停止してから開始する。バックオフもリセットされるため `failed` からの復帰手段 |
| `status [名前...]` | 接続状況を一覧表示する（既定サブコマンド） |
| `list` | 設定に定義されたエントリを一覧表示する（プロセス状態は見ない） |
| `daemon` | 死活監視デーモンをフォアグラウンドで起動する（systemd から利用） |
| `up` | デーモンをバックグラウンドで起動する |
| `down` | デーモンを停止する（配下の全セッションも停止） |
| `reload` | 設定を再読み込みし、差分のみ反映する |
| `logs [名前]` | ログを表示する（`-f` で追従） |
| `test [名前...]` | 設定の妥当性検証と接続テスト（フォワードは張らない） |
| `install-service` | systemd unit を生成・登録する（Linux のみ） |
| `uninstall-service` | systemd unit の登録を解除する（Linux のみ） |
| `config` | 使用中の設定ファイルパスを表示する（`--init` で雛形生成。`-c <PATH>` で作成先を指定できる） |
| `version` | バージョンを表示する |
| `help [サブコマンド]` | ヘルプを表示する |

各サブコマンド固有のオプションは `pfwd help <サブコマンド>` で確認できる。

### 共通オプション

| オプション | 説明 |
| --- | --- |
| `-c, --config <PATH>` | 使用する設定ファイルを指定する（`config --init` では雛形の作成先になる） |
| `-v, --verbose` | 詳細ログを標準エラー出力に出す（`-vv` でさらに詳細） |
| `-q, --quiet` | エラー以外の出力を抑制する |
| `--no-color` | 色付けを無効化する |
| `-h, --help` | ヘルプを表示する |
| `-V, --version` | バージョンを表示する |

色付けは非 TTY 出力時、`NO_COLOR` 環境変数が設定されている場合、`TERM` が `dumb` などの場合も自動的に無効になる。

監視スクリプトから使う場合は `pfwd status --exit-code` を使う。`connected` 以外のエントリが 1 つでもあれば終了コード 4 を返す。

## 常駐化（Linux / systemd）

```console
$ pfwd install-service --user
Generated: /home/komori/.config/systemd/user/port-forwarder.service
Run the following to enable:
  systemctl --user daemon-reload
  systemctl --user enable --now port-forwarder
  loginctl enable-linger komori    # to keep it running after logout
```

- `--user`（既定）はユーザー単位の unit を生成する。SSH 鍵・`ssh-agent` の扱いが素直なため推奨。
- `--system` は `/etc/systemd/system/port-forwarder.service` に生成する。`--run-as <ユーザー名>` で実行ユーザーを指定する（省略すると root 実行になり警告が出る）。
- `--now` を付けると `daemon-reload` と `enable --now` まで自動実行する。
- 解除は `pfwd uninstall-service [--user|--system]`。

macOS はサービス登録に非対応。`pfwd up` によるバックグラウンド起動のみを使う。

## ログ

`global.log_file` を指定した場合は `pfwd logs` で参照できる。

```console
$ pfwd logs -f          # 追従表示
$ pfwd logs db-prod     # 該当エントリの行のみ抽出
```

形式は `YYYY-MM-DDTHH:MM:SS±ZZZZ [LEVEL] [エントリ名] メッセージ`。

```
2026-09-08T21:31:04+0900 [INFO ] [db-prod] connection established (pid=48213)
```

`log_file` 未指定時はログが標準出力に出る。systemd 配下では journald が収集するため、`journalctl --user -u port-forwarder -f`（`--system` の場合は `journalctl -u port-forwarder -f`）で参照する。ローテートは行わないので、ファイル出力を使う場合は `logrotate` 等に任せる。

## トラブルシューティング

| 症状・メッセージ | 対処 |
| --- | --- |
| `bash 4.2 or later is required` | macOS 標準の bash 3.2 で実行している。`brew install bash` を実行する |
| `required command 'yq' not found` | mikefarah/yq 4.31 以上、または kislyuk/yq 2.14 以上を導入し、PATH を通す |
| `required command 'jq' not found` | kislyuk/yq（Python 実装）は jq のラッパーなので、jq も導入する |
| `unsupported yq implementation: ...` | mikefarah/yq でも kislyuk/yq でもない `yq`（`yq read` 構文の v3 など）が PATH にある。対応するどちらかに入れ替える。`pfwd test` の `yq:` 行で認識結果を確認できる |
| `host key for ... is not in known_hosts` | `ssh-keyscan -H <ホスト> >> ~/.ssh/known_hosts` で登録する |
| `identity file ... has too open permissions` | `chmod 600 <鍵ファイル>` を実行する |
| `local port ... is already in use by another process` | 他プロセスが使用中。`local_port` を変更するか、そのプロセスを止める。このエントリは再試行せず `failed` になる |
| `daemon is not running` | `pfwd up` でデーモンを起動する |
| `daemon is already running (pid ...)` | 二重起動。`pfwd down` で停止してから起動する |
| エントリが `failed` のまま | `pfwd restart <名前>` でバックオフをリセットして復帰させる |

主な終了コードは `0`（正常）、`1`（一般的な実行時エラー）、`2`（引数の誤り・存在しないエントリ名）、`3`（設定ファイル未検出・解析失敗）、`4`（接続失敗）、`5`（デーモン未起動）、`6`（デーモン二重起動）、`7`（依存コマンド不足）。全一覧は [docs/SPECS_ja.md](docs/SPECS_ja.md) の 7 章を参照。

## ドキュメント

| ファイル | 内容 |
| --- | --- |
| [docs/SPECS_ja.md](docs/SPECS_ja.md) | 外部設計書。CLI・設定・出力・運用手順の完全な仕様 |
| [docs/DESIGN_ja.md](docs/DESIGN_ja.md) | 内部設計書。データモデル・モジュール構成・シーケンス |
| [IDEA.md](IDEA.md) | 着想メモ |

## 開発

```console
$ task test                                     # ユニットテスト
$ task test-integration                         # 統合テスト（localhost への鍵認証 sshd と python3 が必要）
$ task lint                                     # 静的検査
$ task check                                    # 構文チェック（install.sh は動作対象の bash 3.2 でチェック）
```

テスト用ツールは [aqua](https://aquaproj.github.io/) で管理している（`aqua.yaml`）。`task` コマンド自体も aqua が管理する（`go-task/task`）。

## 制限事項

v1.0 では以下に対応しない。

- リモートフォワード（`ssh -R`）・ダイナミックフォワード（`ssh -D`, SOCKS）
- パスワード認証・キーボードインタラクティブ認証
- macOS の launchd によるサービス登録
- シェル補完
