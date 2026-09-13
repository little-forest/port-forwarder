# port-forwarder (`pfwd`)

**English** | [日本語](README_ja.md)

A single-file bash script that keeps SSH local port forwards (`ssh -L`) up permanently.

Define your forwards by name in a config file, and a daemon health-checks them every
`check_interval` seconds and re-establishes them with exponential backoff when they break.
`pfwd status` shows the state of every entry at a glance.

```console
$ pfwd status
NAME        STATUS      LOCAL            REMOTE                       UPTIME    RETRY  DESCRIPTION
db-prod     connected   127.0.0.1:15432  db.internal:5432             2d 04:11      0  read-only tunnel to prod DB
redis-stg   connected   127.0.0.1:16379  redis.internal:6379          05:22         0
metrics     retrying    127.0.0.1:19090  prom.internal:9090           -             3  next attempt in 40s

3 entries: 2 connected, 1 retrying
```

## Requirements

| Command | Version | Required | Notes |
| --- | --- | --- | --- |
| `bash` | 4.2 or later | ✔ | The bash 3.2 shipped with macOS does not work (`brew install bash`). Exits with code 7 when unsatisfied |
| `ssh` | OpenSSH 7.4 or later | ✔ | Standard on both OSes |
| `yq` | mikefarah/yq 4.31+ **or** kislyuk/yq 2.14+ | ✔ | Either the Go or the Python implementation works |
| `jq` | 1.5 or later | | Required only when `yq` is kislyuk/yq (the Python implementation) |
| `nc` | - | | Optional. Falls back to bash `/dev/tcp` when absent |

Supported platforms are RedHat-family Linux (RHEL / Rocky / AlmaLinux / Fedora) and macOS.

Three prerequisites on the SSH side:

- **Public-key authentication** must be configured for every destination (password and keyboard-interactive auth are not supported).
- The host key must already be in `known_hosts`. `StrictHostKeyChecking=yes` is fixed, so unknown hosts are never contacted.
- A passphrase-less key is recommended. To use a passphrase-protected key, run `ssh-agent` and pass `SSH_AUTH_SOCK` through to the daemon.

## Installation

Fetch and install the latest release of `pfwd` with a single line.

```console
$ curl -fsSL https://raw.githubusercontent.com/little-forest/port-forwarder/main/install.sh | bash
```

The default destination depends on the OS.

| OS | Default destination | sudo |
| --- | --- | --- |
| Linux | `/usr/local/bin` | Switches to `sudo` automatically, and only when the directory is not writable |
| macOS | `~/.local/bin` | Not needed |

`~/.local/bin` is not part of the default PATH on macOS, so the installer tells you how to add it when it is missing.

The installer honours these environment variables.

| Variable | Default | Meaning |
| --- | --- | --- |
| `PFWD_INSTALL_DIR` | The per-OS default above | Destination directory |
| `PFWD_VERSION` | The tag of the latest release | The ref to install. Set it to `main` to install the development version |
| `NO_COLOR` | - | Disable colored output (<https://no-color.org/>) |

```console
$ curl -fsSL .../install.sh | PFWD_INSTALL_DIR=~/bin bash   # change the destination
$ curl -fsSL .../install.sh | PFWD_VERSION=v1.0.0 bash      # pin a version
$ curl -fsSL .../install.sh | PFWD_VERSION=main bash        # install the development version
```

Missing dependencies (`bash` 4.2 or later / `ssh` / `yq`) are reported as warnings only; the installation itself still succeeds.

### Installing manually

Just copy the single `pfwd` file. There is nothing to build.

```console
$ install -m 755 pfwd ~/.local/bin/pfwd              # per user (recommended)
$ sudo install -m 755 pfwd /usr/local/bin/pfwd       # system wide
```

On macOS, install the dependencies first.

```console
$ brew install bash yq
```

### Uninstalling

Just remove the file that was installed.

```console
$ rm -f ~/.local/bin/pfwd          # the macOS default
$ sudo rm -f /usr/local/bin/pfwd   # the Linux default
```

The config files under `~/.config/port-forwarder/` are left behind; delete them too if you no longer need them.

## Quick start

### 1. Create a config template

```console
$ pfwd config --init
Created: /home/komori/.config/port-forwarder/config.yaml
Edit the file and run 'pfwd test' to validate.
```

To create it somewhere else, pass `-c, --config <PATH>` before `config`. Such a path is not
searched automatically, so `-c` is needed on subsequent runs as well.

```console
$ pfwd --config ~/work/pfwd.yaml config --init
Created: /home/komori/work/pfwd.yaml
Edit the file and run 'pfwd test' to validate.
Note: this path is not searched automatically. Run 'pfwd --config /home/komori/work/pfwd.yaml <subcommand>'.
```

### 2. Edit the config file

The `example` entry in the template has `enabled: false`. Rewrite it for your own destination and set `enabled: true`.

### 3. Validate

Checks the config, SSH reachability and local port availability without establishing any forward.

```console
$ pfwd test
Config: /home/komori/.config/port-forwarder/config.yaml

[  OK  ] db-prod    config valid, ssh reachable, local port free
[  OK  ] redis-stg  config valid, ssh reachable, local port free

2 passed, 0 warning, 0 failed
```

### 4. Start the daemon

Every entry with `enabled: true` is forwarded, and kept alive from then on.

```console
$ pfwd up
daemon started (pid=48120)
```

### 5. Check the status

```console
$ pfwd status
```

Running `pfwd` with no arguments does the same thing as `pfwd status`.

### 6. Stop

The daemon and all SSH sessions under it are terminated.

```console
$ pfwd down
```

> [!IMPORTANT]
> `start` / `stop` / `restart` / `reload` **require the daemon to be running**.
> Without it they do nothing and exit with code 5, pointing you at `pfwd up`.

## Configuration

The following paths are searched in order, and the first hit is used.

1. The path given to `--config`
2. `$XDG_CONFIG_HOME/port-forwarder/config.yaml` (or `~/.config/port-forwarder/config.yaml` when unset)
3. `/etc/port-forwarder/config.yaml`

If a `conf.d/` directory sits next to the chosen config file, its `*.yaml` (and `*.yml`) files are read in name order and merged last-wins.

The top level has two keys: `global` (optional) and `entries` (required). Each key under `entries` is an entry name.

```yaml
global:
  check_interval: 30          # health check interval (sec); minimum 5
  log_file: ~/.local/state/port-forwarder/port-forwarder.log   # stdout when unset

entries:
  db-prod:
    description: read-only tunnel to prod DB
    host: bastion.example.com     # required: SSH destination (bastion)
    user: komori
    identity: ~/.ssh/id_ed25519
    local_port: 15432             # required: local listening port
    remote_host: db.internal      # target as seen from the bastion; default localhost
    remote_port: 5432             # required: destination port

  redis-stg:
    host: stg-bastion.example.com
    user: komori
    local_port: 16379
    remote_host: redis.internal
    remote_port: 6379
    check_mode: tcp               # to avoid health-check connections to the target
```

### Commonly used entry keys

| Key | Required | Default | Description |
| --- | --- | --- | --- |
| `host` | ✔ | - | SSH destination (bastion) host |
| `local_port` | ✔ | - | Local listening port (1-65535) |
| `remote_port` | ✔ | - | Destination port |
| `user` | | `$USER` | SSH user name |
| `remote_host` | | `localhost` | Target host as seen from the bastion |
| `identity` | | - | Private key path. Falls back to `~/.ssh/config` when unset |
| `bind_address` | | `127.0.0.1` | Local listening address |
| `enabled` | | `true` | `false` excludes the entry from automatic start |
| `check_mode` | | `remote` | Health check method (see below) |
| `description` | | - | Description shown in listings |

Entry names may use `[A-Za-z0-9._-]` and must be 1-32 characters long.

### Commonly used `global` keys

| Key | Default | Description |
| --- | --- | --- |
| `check_interval` | `30` | Health check interval in seconds; minimum 5 |
| `connect_timeout` | `10` | SSH connect timeout in seconds |
| `retry_initial` | `5` | Initial reconnect wait in seconds |
| `retry_max` | `300` | Upper bound of the exponential backoff in seconds |
| `retry_limit` | `0` | Max consecutive failures; `0` means unlimited |
| `log_file` | (unset) | Log destination. **Logs go to stdout when unset** |

See section 4.3 of [docs/SPECS.md](docs/SPECS.md) for the complete key reference.

### Health check methods (`check_mode`)

| Value | What it checks |
| --- | --- |
| `process` | Whether the SSH process is alive. Cheapest |
| `tcp` | Whether the local port accepts a TCP connection |
| `remote` (default) | Whether traffic actually reaches the target through the local port. Most reliable |

The default `remote` also detects the case where the SSH process is alive but forwarding no longer works.
However it **opens a real TCP connection to the target every `check_interval`**, which leaves connection
logs on the target. Use `check_mode: tcp` for entries where you want to avoid that.

## Commands

```
pfwd <subcommand> [options] [entry...]
```

| Subcommand | Description |
| --- | --- |
| `start [name...]` | Start forwarding. With no name, all `enabled` entries |
| `stop [name...]` | Stop forwarding. With no name, all entries |
| `restart [name...]` | Stop and start again. This also resets the backoff, so it is how you recover a `failed` entry |
| `status [name...]` | Show the connection status of each entry (default subcommand) |
| `list` | List the entries in the config file (process state is not inspected) |
| `daemon` | Run the monitoring daemon in the foreground (used by systemd) |
| `up` | Start the daemon in the background |
| `down` | Stop the daemon and all sessions under it |
| `reload` | Reload the config and apply only the difference |
| `logs [name]` | Show logs (`-f` to follow) |
| `test [name...]` | Validate the config and check connectivity (no forward is created) |
| `install-service` | Generate and register a systemd unit (Linux only) |
| `uninstall-service` | Remove the systemd unit (Linux only) |
| `config` | Show the config file in use (`--init` writes a template; `-c <PATH>` chooses where) |
| `version` | Show the version |
| `help [subcommand]` | Show help |

Run `pfwd help <subcommand>` for the options specific to each subcommand.

### Common options

| Option | Description |
| --- | --- |
| `-c, --config <PATH>` | Use the specified config file (with `config --init`, where the template is created) |
| `-v, --verbose` | Verbose output to stderr (`-vv` for more) |
| `-q, --quiet` | Suppress everything but errors |
| `--no-color` | Disable colored output |
| `-h, --help` | Show help |
| `-V, --version` | Show the version |

Color is also disabled automatically when stdout is not a TTY, when the `NO_COLOR` environment variable is set, and when `TERM` is `dumb` and similar.

For monitoring scripts, use `pfwd status --exit-code`: it exits with code 4 if any entry is not `connected`.

## Running as a service (Linux / systemd)

```console
$ pfwd install-service --user
Generated: /home/komori/.config/systemd/user/port-forwarder.service
Run the following to enable:
  systemctl --user daemon-reload
  systemctl --user enable --now port-forwarder
  loginctl enable-linger komori    # to keep it running after logout
```

- `--user` (default) generates a user unit. Recommended, since SSH keys and `ssh-agent` are handled naturally.
- `--system` writes to `/etc/systemd/system/port-forwarder.service`. Use `--run-as <user>` to pick the user; omitting it means running as root and prints a warning.
- `--now` additionally runs `daemon-reload` and `enable --now`.
- Remove it with `pfwd uninstall-service [--user|--system]`.

macOS has no service registration. Use `pfwd up` to run the daemon in the background instead.

## Logs

When `global.log_file` is set, `pfwd logs` reads it.

```console
$ pfwd logs -f          # follow
$ pfwd logs db-prod     # only the lines of that entry
```

The format is `YYYY-MM-DDTHH:MM:SS±ZZZZ [LEVEL] [entry] message`.

```
2026-09-08T21:31:04+0900 [INFO ] [db-prod] connection established (pid=48213)
```

When `log_file` is unset, logs go to stdout. Under systemd journald collects them, so read them with `journalctl --user -u port-forwarder -f` (or `journalctl -u port-forwarder -f` for `--system`). Logs are never rotated, so leave size management of a log file to `logrotate` or similar.

## Troubleshooting

| Symptom / message | What to do |
| --- | --- |
| `bash 4.2 or later is required` | You are running the bash 3.2 shipped with macOS. Run `brew install bash` |
| `required command 'yq' not found` | Install mikefarah/yq 4.31+ or kislyuk/yq 2.14+ and put it on your `PATH` |
| `required command 'jq' not found` | kislyuk/yq (the Python implementation) wraps jq, so install jq as well |
| `unsupported yq implementation: ...` | The `yq` on your `PATH` is neither mikefarah/yq nor kislyuk/yq (e.g. the `yq read` syntax of v3). Replace it with one of the supported ones; the `yq:` line of `pfwd test` shows what was recognized |
| `host key for ... is not in known_hosts` | Register it: `ssh-keyscan -H <host> >> ~/.ssh/known_hosts` |
| `identity file ... has too open permissions` | Run `chmod 600 <key file>` |
| `local port ... is already in use by another process` | Another process holds the port. Change `local_port` or stop that process. Such an entry is not retried and goes straight to `failed` |
| `daemon is not running` | Start the daemon with `pfwd up` |
| `daemon is already running (pid ...)` | Already started. Run `pfwd down` first |
| An entry stays `failed` | Run `pfwd restart <name>` to reset the backoff and recover it |

The main exit codes are `0` (success), `1` (general runtime error), `2` (bad arguments or unknown entry name), `3` (config not found or unparsable), `4` (connection failure), `5` (daemon not running), `6` (daemon already running) and `7` (missing dependency). See chapter 7 of [docs/SPECS.md](docs/SPECS.md) for the full list.

## Documentation

| File | Contents |
| --- | --- |
| [docs/SPECS.md](docs/SPECS.md) | External design. The complete specification of the CLI, config, output and operations |
| [docs/DESIGN_ja.md](docs/DESIGN_ja.md) | Internal design. Data model, module structure, sequences (Japanese) |
| [IDEA.md](IDEA.md) | The original idea notes (Japanese) |

## Development

```console
$ bats test/                                    # unit tests
$ PFWD_IT=1 bats test/test_integration.bats     # integration tests (needs sshd on localhost with key auth, and python3)
$ shellcheck -x -s bash pfwd install.sh         # static checks
```

The test toolchain is managed with [aqua](https://aquaproj.github.io/) (`aqua.yaml`).

## Limitations

The following are out of scope for v1.0.

- Remote forwarding (`ssh -R`) and dynamic forwarding (`ssh -D`, SOCKS)
- Password and keyboard-interactive authentication
- Service registration via launchd on macOS
- Shell completion
