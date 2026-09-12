# port-forwarder External Design

**English** | [日本語](SPECS_ja.md)

Based on [IDEA.md](../IDEA.md), this document defines only the **behaviour as seen by the user**
(CLI, config file, output, operational procedures).
The internal implementation (function decomposition, how process control is realised, etc.) is out of
scope here and is defined separately in the internal design document.

- Target version: v1.0 (first edition)
- Written: 2026-09-08

---

## 1. Overview

### 1.1 Purpose

A service that keeps SSH port forwards to arbitrary remote hosts up permanently.
Once configured, it reconnects automatically when the connection drops, so the local port stays
usable at all times.

### 1.2 Value

| Problem | How this tool solves it |
| --- | --- |
| Re-running `ssh -L` by hand is tedious | Health-checks the session and reconnects automatically |
| Typing out bastions and ports every time is cumbersome | Define them by name in a config file and operate on them by name |
| No way to tell what is currently connected | `status` lists the state of every connection |
| Closing the terminal kills the forward | Daemonisation / registration as a systemd service |

### 1.3 Scope

| Item | Support |
| --- | --- |
| Forward type | Local forwarding only (equivalent to `ssh -L`) |
| Authentication | SSH public key authentication only (password and keyboard-interactive are not supported) |
| Supported OS | RedHat-family Linux (RHEL / Rocky / AlmaLinux / Fedora), macOS |
| Implementation | bash script |
| Service registration | Linux: systemd only (both user and system). On macOS only manual residency via `pfwd up` is supported; no launchd registration |

> Remote forwarding (`-R`) and dynamic forwarding (`-D`) are out of scope for v1.0. They are listed as
> future extensions in chapter 12.

### 1.4 Terminology

| Term | Meaning |
| --- | --- |
| Entry | A single port forward definition in the config file. Has a unique "name" |
| Session | The SSH process actually running for an entry |
| Daemon | The resident process that monitors and maintains all entries |
| Health check | The periodic check of whether a session is actually usable |

---

## 2. Prerequisites

### 2.1 Required commands

| Command | Purpose | How to obtain |
| --- | --- | --- |
| `bash` (4.2 or later) | Runtime | Linux: standard / macOS: `brew install bash` (associative arrays and `declare -g` are used to hold config and state, so versions older than 4.2 will not work. This is checked at startup and the tool exits with code 7 if unmet) |
| `ssh` (OpenSSH 7.4+) | The forwarding itself | Standard on both OSes |
| `yq` (mikefarah/yq v4 series) | Parsing the config file (YAML) | Assumed to be installed and on `PATH` (installation instructions are out of scope for this design) |
| `nc` or bash `/dev/tcp` | Reachability check of the local port | Standard (falls back to `/dev/tcp` when `nc` is absent) |
| `awk` / `sed` / `grep` | Output formatting | Standard on both OSes |
| `date` / `sleep` / `kill` | Monitoring loop | Standard on both OSes |

> No dependency on extra commands such as `ss` or `lsof`. If present, they are optionally used to
> improve the accuracy of diagnostic information.

`yq` is assumed to be **mikefarah/yq v4 or later** (the Go implementation). Installing it and setting
`PATH` is the user's responsibility; this tool neither guides the installation nor detects the version
automatically.
If it is not installed, the tool exits with a command-not-found error just like any other missing
dependency (exit code 7).

### 2.2 SSH-side prerequisites

- Public key authentication must already be configured for each destination.
- If a passphrase-protected key is used, `ssh-agent` must be available (see 9.2).
- The host key must already be registered in `known_hosts`. For unregistered hosts the tool **does not
  attempt to connect and fails**, prompting the user to register the key (it never applies
  `StrictHostKeyChecking=no` on its own).

---

## 3. Command structure

The command is named `pfwd`.

```
pfwd <subcommand> [options] [entry-name...]
```

### 3.1 Subcommands

| Subcommand | Description |
| --- | --- |
| `start [name...]` | Start the forwards for the given entries. When omitted, all `enabled` entries |
| `stop [name...]` | Stop the forwards for the given entries. When omitted, all entries |
| `restart [name...]` | Stop and then start |
| `status [name...]` | List the connection status (default subcommand) |
| `list` | List the entries defined in the config file (does not look at connection state) |
| `daemon` | Run the health-check daemon in the foreground (used from systemd) |
| `up` | Start the daemon in the background |
| `down` | Stop the daemon (all sessions under it are stopped too) |
| `reload` | Reload the config file and apply only the differences |
| `logs [name]` | Show the log. `-f` follows it |
| `test [name...]` | Validate the config and test connectivity (does not establish forwards) |
| `install-service` | Generate and register a systemd unit (Linux only) |
| `uninstall-service` | Unregister the systemd unit (Linux only) |
| `config` | Show the config file path / generate a template |
| `version` | Show the version |
| `help [subcommand]` | Show help |

Running `pfwd` with no arguments behaves the same as `pfwd status`.

### 3.2 Common options

| Option | Description |
| --- | --- |
| `-c, --config <PATH>` | Specify the config file to use; with `config --init` it is where the template is created (see 4.5) |
| `-v, --verbose` | Write verbose logs to standard error (`-vv` for even more detail) |
| `-q, --quiet` | Suppress all output except errors |
| `--no-color` | Disable colouring (automatically disabled when not a TTY) |
| `-h, --help` | Show help |
| `-V, --version` | Show the version |

---

## 4. Config file

### 4.1 Location

The following are searched in order and the first one found is used.

1. The path given with `--config`
2. `$XDG_CONFIG_HOME/port-forwarder/config.yaml` (when unset, `~/.config/port-forwarder/config.yaml`)
3. `/etc/port-forwarder/config.yaml` (system-wide config)

If `~/.config/port-forwarder/conf.d/*.yaml` exists, those files are loaded in name order after the main
config and merged.
The merge rule is "last one wins": `global` is overridden per key and `entries` per entry. Both the
`.yaml` and `.yml` extensions are accepted.

### 4.2 Format

**YAML format** is used. `yq` is used for parsing.

There are two top-level keys: `global` (optional) and `entries` (required). `entries` is a map keyed by
entry name; since duplicate keys are detectable by the YAML spec itself, uniqueness of names is
guaranteed.

```yaml
# Global settings (optional; defaults are used when omitted)
global:
  check_interval: 30          # Health check interval (seconds)
  connect_timeout: 10         # SSH connection timeout (seconds)
  retry_initial: 5            # Initial wait before reconnecting (seconds)
  retry_max: 300              # Upper bound of the reconnect wait (seconds)
  log_file: ~/.local/state/port-forwarder/port-forwarder.log  # Standard output when unset

# Entry definitions. The key is the entry name (unique)
entries:
  db-prod:
    description: read-only tunnel to prod DB
    host: bastion.example.com     # Required: SSH destination host
    user: komori                  # Optional: defaults to $USER / the ~/.ssh/config setting
    port: 22                      # Optional: SSH port. Default 22
    identity: ~/.ssh/id_ed25519   # Optional: private key
    local_port: 15432             # Required: local listening port
    remote_host: db.internal      # Optional: default localhost (host as seen from the bastion)
    remote_port: 5432             # Required: port on the remote side
    bind_address: 127.0.0.1       # Optional: default 127.0.0.1
    enabled: true                 # Optional: default true. false excludes it from auto-start
    check_mode: remote            # Optional: process | tcp | remote. Default remote

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
    ssh_options:                  # Extra ssh -o settings are written as a list
      - ExitOnForwardFailure=yes
      - Compression=yes
```

- Value types follow YAML (port numbers are numbers, `enabled` is a boolean). Quoting them as strings is
  also accepted.
- `ExitOnForwardFailure=yes` is **always applied by default**, so there is no need to list it in
  `ssh_options` as the `metrics` example above does. Because `ssh_options` entries are placed after the
  defaults, they can also override the defaults.
- A leading `~` in a path value is expanded to the home directory of the executing user.
- The display order of entries follows the order written in the YAML.

### 4.3 Parameter reference

#### The `[global]` section

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `check_interval` | integer (s) | `30` | Interval between health checks. Minimum 5 |
| `connect_timeout` | integer (s) | `10` | Timeout for establishing the SSH connection |
| `retry_initial` | integer (s) | `5` | Initial wait after a failed connection |
| `retry_max` | integer (s) | `300` | Upper bound of the exponential backoff wait |
| `retry_limit` | integer | `0` | Maximum number of consecutive failures. `0` means unlimited |
| `server_alive_interval` | integer (s) | `15` | SSH keepalive interval |
| `server_alive_count_max` | integer | `3` | Allowed number of missed keepalive responses |
| `log_file` | path | (unset) | Log destination. **Standard output when unset** |

The wait times used by the TCP probe of the health check are internal constants (3-second connect
timeout / 1.0-second wait for the `remote` check) and cannot be configured in v1.0. Room is left to
expose them later as `global.check_timeout`.

#### The entry section

| Key | Required | Default | Description |
| --- | --- | --- | --- |
| `host` | ✔ | - | SSH destination (bastion) hostname / IP |
| `local_port` | ✔ | - | Local listening port (1-65535) |
| `remote_port` | ✔ | - | Destination port |
| `user` | | `$USER` | SSH user name |
| `port` | | `22` | SSH port |
| `identity` | | - | Private key path. When unset, ssh defaults / `~/.ssh/config` apply |
| `remote_host` | | `localhost` | Destination host as seen from the bastion |
| `bind_address` | | `127.0.0.1` | Local listening address. A warning is emitted for `0.0.0.0` |
| `description` | | - | Description shown in the listings |
| `enabled` | | `true` | When `false`, excluded from `start` (when no name is given) |
| `check_mode` | | `remote` | Health check method (see 5.2) |
| `check_interval` | | global value | Per-entry monitoring interval |
| `ssh_options` | | - | Extra `ssh -o` settings. Written as a list of strings |

### 4.4 Naming and validation rules

Entry names match `[A-Za-z0-9._-]{1,32}`.

The following are validated at load time. If any of them is violated, **only that entry is disabled**
with a warning and the other entries continue to be processed.

- A required key is missing
- A port number is not an integer in 1-65535
- Duplicate `local_port` (across all entries after merging)
- Unknown key name (warning only, processing continues)
- The specified `identity` file does not exist
- The specified `identity` file has permissions open to other users (rejected up front because `ssh`
  itself would refuse it)
- `bind_address` is `0.0.0.0` / `::` (warning only, processing continues)

In the following cases the whole config is treated as an error and the tool exits immediately
(exit code 3).

- The file cannot be parsed as YAML (the `yq` error is presented together with the line number)
- The top level has no `entries`, or `entries` is not a map
- `entries` is empty

### 4.5 Template generation

```console
$ pfwd config --init
Created: /home/komori/.config/port-forwarder/config.yaml
Edit the file and run 'pfwd test' to validate.
```

If the file already exists it is not overwritten and an error is returned (`--force` allows
overwriting).

The destination can be chosen with the common option `-c, --config <PATH>` (3.2). Such a path is
not part of the search order in 4.1, so a `Note:` line points out that `-c` is needed on subsequent
runs as well.

```console
$ pfwd --config ~/work/pfwd.yaml config --init
Created: /home/komori/work/pfwd.yaml
Edit the file and run 'pfwd test' to validate.
Note: this path is not searched automatically. Run 'pfwd --config /home/komori/work/pfwd.yaml <subcommand>'.
```

If the destination is an existing directory it is an error (exit code 1); it is not completed to
`<DIR>/config.yaml`. The same applies with `--force`.

`config` takes no positional arguments. Passing one, as in `pfwd config --init ~/foo.yaml`, prints
the usage and exits with code 2, so that the file is never created at the default path by mistake.

---

## 5. Health check and reconnect behaviour

### 5.1 State transitions

There are six entry states visible to the user.

| State | Display | Meaning |
| --- | --- | --- |
| `connected` | green | Forwarding normally. The local port is usable |
| `connecting` | yellow | Establishing the connection (first connection or a reconnect attempt) |
| `retrying` | yellow | The connection failed and it is waiting on backoff |
| `stopped` | grey | Stopped by user operation |
| `disabled` | grey | `enabled = false` in the config |
| `failed` | red | The retry limit was reached, or it cannot start due to a config problem |

```
        start                 established
stopped ─────> connecting ───────────────> connected
   ^               │                           │
   │               │ failure                   │ drop detected
   │               v                           v
   └──── stop ── retrying <────────────────────┘
                   │ retry_limit reached
                   v
                 failed
```

### 5.2 Check method (`check_mode`)

| Value | What is checked | Use |
| --- | --- | --- |
| `process` | Whether the SSH process is alive | Lightest. Cannot detect a zombie state |
| `tcp` | Whether the local port accepts TCP connections | A light check. Process alive + LISTEN confirmed |
| `remote` (default) | Whether the destination is actually reachable through the local port | The most reliable. Detects failures beyond the bastion too |

The default is `remote` so that the state where the SSH process is alive but only the forward has
stopped working is reliably detected. Because this method opens a TCP connection to the destination on
every check, keep the following in mind.

- Connection logs caused by the health check are recorded on the destination server every
  `check_interval`.
- The check only confirms that the handshake succeeds; no data is sent and it disconnects immediately.
- For entries where you do not want extra connection logs, or want to avoid the connection cost,
  specify `check_mode: tcp`.

### 5.3 Reconnect policy

- When a drop is detected, the existing SSH process is reliably terminated first, then the reconnect
  happens.
- The reconnect wait uses exponential backoff: it starts at `retry_initial`, doubles on every failure
  and is capped at `retry_max`.
  Example: `5s → 10s → 20s → 40s → 80s → 160s → 300s → 300s ...`
- If a connection **lasts 60 seconds or more**, the backoff is reset and the next initial wait goes back
  to `retry_initial`.
- An entry that reaches `retry_limit` becomes `failed` and stops retrying automatically. Recovery
  requires `pfwd restart <name>`.
- If the local port is in use by another process, no retry is made: the entry goes straight to `failed`
  and the fact that the port is in use is written to the log.

### 5.4 Daemon behaviour

- `pfwd up` / `pfwd daemon` start all `enabled` entries and health-check them every `check_interval`.
- A double start is prevented with a PID file; if one is already running an explicit error is returned
  (exit code 6).
- `down` while the daemon is not running does nothing and succeeds (exit code 0) — it is idempotent.
- On `SIGTERM` / `SIGINT` all SSH processes under the daemon are terminated before it exits (no orphan
  processes are left behind).
- On `SIGHUP` the config is reloaded (equivalent to `pfwd reload`).

### 5.5 Differential application by `reload`

| Config change | Behaviour |
| --- | --- |
| Entry added | The added entry is started |
| Entry removed | The corresponding session is stopped |
| Connection parameter changed | Only that entry is restarted |
| `enabled` changed to false | The session is stopped and the entry becomes `disabled` |
| Only `description` changed | The session is kept and only the display is updated |
| `[global]` changed | Applied from the next monitoring cycle (existing sessions are kept) |

---

## 6. Output specification

### 6.1 `pfwd status`

```console
$ pfwd status
NAME        STATUS      LOCAL            REMOTE                       UPTIME    RETRY  DESCRIPTION
db-prod     connected   127.0.0.1:15432  db.internal:5432             2d 04:11      0  read-only tunnel to prod DB
redis-stg   connected   127.0.0.1:16379  redis.internal:6379          05:22         0
metrics     retrying    127.0.0.1:19090  prom.internal:9090           -             3  next attempt in 40s
legacy      disabled    127.0.0.1:18080  legacy.internal:80           -             -  migrated
batch       failed      127.0.0.1:12222  batch.internal:22            -            10  local port in use

5 entries: 2 connected, 1 retrying, 1 disabled, 1 failed
```

- Colouring: `connected` = green, `connecting` / `retrying` = yellow, `failed` = red,
  `stopped` / `disabled` = grey.
- No colour is applied for non-TTY output or when `--no-color` is given.
- When the daemon is not running, `daemon: not running` is shown on the first line and each entry is
  judged and displayed from the actual process state.
- The output is the formatted table above and nothing else. To look at specific entries only, narrow
  them down with arguments, as in `pfwd status <name...>`.

### 6.2 `pfwd list`

Shows the config contents only (fast, because it does not look at process state).

```console
$ pfwd list
NAME        ENABLED  SSH                          LOCAL            REMOTE
db-prod     yes      komori@bastion.example.com   127.0.0.1:15432  db.internal:5432
redis-stg   yes      komori@stg-bastion.exam...   127.0.0.1:16379  redis.internal:6379
legacy      no       komori@old-bastion.exam...   127.0.0.1:18080  legacy.internal:80
```

### 6.3 `pfwd start` / `stop` / `restart`

Progress is shown as one line per entry.

```console
$ pfwd start db-prod redis-stg
[  OK  ] db-prod    connected (127.0.0.1:15432 -> db.internal:5432)
[  OK  ] redis-stg  connected (127.0.0.1:16379 -> redis.internal:6379)
2 started, 0 failed
```

On failure:

```console
$ pfwd start metrics
[FAILED] metrics    ssh: connect to host bastion.example.com port 22: Connection timed out
0 started, 1 failed
```

- `start` on an already connected entry is treated as a success (idempotent) and shows
  `[ SKIP ]  already connected`.
- Specifying a non-existent entry name exits with an error (exit code 2).
- `start` / `stop` / `restart` / `reload` **require the daemon to be running**; if it is not, they do
  nothing, exit with code 5 and point the user at `pfwd up`.

### 6.4 `pfwd test`

Validates the config and connectivity without establishing forwards.

```console
$ pfwd test
Config: /home/komori/.config/port-forwarder/config.yaml

[  OK  ] db-prod    config valid, ssh reachable, local port free
[  OK  ] redis-stg  config valid, ssh reachable, local port free
[ WARN ] metrics    config valid, ssh reachable, local port 19090 already in use
[FAILED] broken     missing required key: entries.broken.remote_port

3 passed, 1 warning, 1 failed
```

The summary line counts `[  OK  ]` as passed, `[ WARN ]` as warning and `[FAILED]` as failed (each
entry is counted in exactly one of them).

### 6.5 Logging

- The destination is the path given in `log_file`. **When unset, output goes to standard output.**
- Format: `YYYY-MM-DDTHH:MM:SS±ZZZZ [LEVEL] [entry-name] message`
- Example:

```
2026-09-08T21:31:04+0900 [INFO ] [db-prod] connection established (pid=48213)
2026-09-08T22:03:47+0900 [WARN ] [metrics] health check failed (tcp 127.0.0.1:19090 refused)
2026-09-08T22:03:47+0900 [INFO ] [metrics] reconnecting in 5s (attempt 1)
2026-09-08T22:04:02+0900 [ERROR] [metrics] ssh exited with status 255: Connection timed out
```

- The three levels `INFO` / `WARN` / `ERROR` are always emitted. `DEBUG` is emitted additionally only
  when run with `-v`.
- Logs are not rotated. When file output is used, size management is left to OS-standard mechanisms such
  as `logrotate`.
- `pfwd logs -f` follows the log. `pfwd logs <name>` extracts only the lines for that entry. When
  `log_file` is unset there is no file, so the tool explains how to read the log with `journalctl` (on
  macOS, run in the foreground or set `log_file`) and exits (exit code 0).
- When output goes to standard output, journald collects it under systemd, so it can be read with
  `journalctl -u port-forwarder`.

---

## 7. Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `1` | General runtime error |
| `2` | Bad arguments or options, or a non-existent entry name |
| `3` | Config file not found / failed to parse |
| `4` | Connection failed for one or more entries |
| `5` | The daemon is not running (for operations other than `status` that require it) |
| `6` | The daemon is already running (double start of `up`) |
| `7` | A required command is missing |

`status` returns `0` whenever the command itself succeeds, regardless of entry states. However, with
`--exit-code` it returns `4` if there is even one entry that is not `connected` (for integration with
monitoring scripts). `--exit-code` is an option specific to `status`, not one of the common options in
3.2.

---

## 8. File layout

### 8.1 Running per user (default)

| Kind | Path |
| --- | --- |
| Executable | `~/.local/bin/pfwd` |
| Config | `~/.config/port-forwarder/config.yaml`, `~/.config/port-forwarder/conf.d/*.yaml` |
| Log | The path given in `log_file` (standard output when unset; recommended value `~/.local/state/port-forwarder/port-forwarder.log`) |
| Runtime state (PID and state files) | `${XDG_RUNTIME_DIR}/port-forwarder/` (when `XDG_RUNTIME_DIR` is unset, `~/.local/state/port-forwarder/run/`) |
| SSH ControlPath | Under the runtime directory above |

### 8.2 Running system-wide

| Kind | Path |
| --- | --- |
| Executable | `/usr/local/bin/pfwd` |
| Config | `/etc/port-forwarder/config.yaml`, `/etc/port-forwarder/conf.d/*.yaml` |
| Log | The path given in `log_file` (standard output when unset; recommended value `/var/log/port-forwarder/port-forwarder.log`) |
| Runtime state | `/run/port-forwarder/` |

When `/run` is unavailable on macOS, `/usr/local/var/run/port-forwarder/` is used. Note that because
macOS does not get service registration, system-wide resident operation is assumed on Linux only.

---

## 9. Service registration

Service registration targets Linux (systemd) only. On macOS, start in the background with `pfwd up` and
prepare a residency mechanism on the user's side if needed.

### 9.1 Linux (systemd)

```console
$ pfwd install-service --user
Generated: /home/komori/.config/systemd/user/port-forwarder.service
Run the following to enable:
  systemctl --user daemon-reload
  systemctl --user enable --now port-forwarder
  loginctl enable-linger komori    # to keep it running after logout
```

- `--user` (default): generates a per-user systemd unit. Recommended, because SSH keys and `ssh-agent`
  are handled more naturally.
- `--system`: generates a system unit at `/etc/systemd/system/port-forwarder.service`. Use
  `--run-as <user-name>` to specify the executing user (running as root is discouraged and a warning is
  shown).
- Behaviour of the generated unit:
  - `ExecStart=/usr/local/bin/pfwd daemon`
  - `ExecReload=/bin/kill -HUP $MAINPID`
  - `Restart=on-failure`, `RestartSec=10`
  - `After=network-online.target`
- With `pfwd install-service --now`, `daemon-reload` and `enable --now` are run automatically as well.

### 9.2 Handling passphrase-protected keys

- Because the daemon cannot prompt interactively, one of the following is suggested to the user when a
  passphrase-protected key is used.
  1. Prepare a dedicated key without a passphrase (recommended; combine it with `command=` restrictions
     or `permitopen`).
  2. Start `ssh-agent` beforehand and hand `SSH_AUTH_SOCK` to the service (specified with
     `Environment=` in a systemd user unit).
- If a connection fails in a state where a passphrase would be required, the log states
  "passphrase-protected key requires ssh-agent" explicitly and the entry becomes `failed` before
  entering the retry loop.

---

## 10. Error message policy

Every message contains all three of "**what happened / why / what to do about it**".

| Situation | Example message |
| --- | --- |
| Config file not found | `error: config file not found. Run 'pfwd config --init' to create one at ~/.config/port-forwarder/config.yaml` |
| YAML syntax error | `error: failed to parse config.yaml: bad indentation of a mapping entry at line 23, column 5` |
| Missing required key | `error: [broken] missing required key 'remote_port' (entries.broken)` |
| Duplicate port | `error: local_port 15432 is used by both [db-prod] and [db-copy]` |
| Local port in use | `error: [db-prod] local port 15432 is already in use by another process` |
| Host key not registered | `error: [db-prod] host key for bastion.example.com is not in known_hosts. Run: ssh-keyscan -H bastion.example.com >> ~/.ssh/known_hosts` |
| Bad key file permissions | `error: [db-prod] identity file ~/.ssh/id_ed25519 has too open permissions (0644). Run: chmod 600 ~/.ssh/id_ed25519` |
| Missing dependency | `error: required command 'yq' not found. Install it and make sure it is in your PATH.` |
| Daemon double start | `error: daemon is already running (pid 48120). Use 'pfwd down' to stop it.` |
| Unknown entry name | `error: no such entry 'db-pord'` |
| Config destination is a directory | `error: /home/komori/work is a directory. Specify the config file itself (e.g. /home/komori/work/config.yaml)` |
| Extra arguments to `config` | `error: 'config' takes no arguments. Use 'pfwd --config <PATH> config --init' to choose where the file is created.` |

---

## 11. Non-functional requirements (the user-visible ones)

| Item | Requirement |
| --- | --- |
| Startup time | `pfwd status` returns a result within 1 second (up to 50 entries) |
| Resources while resident | With a 30-second check interval and 10 entries, CPU usage is essentially 0% at steady state and memory is only the shell plus the SSH processes |
| Recovery time after a drop | With the default settings, reconnection starts within `check_interval + retry_initial` (= 35 seconds) at most |
| Number of concurrent entries | Operation is guaranteed up to 100 entries |
| Safety | The default `bind_address` is `127.0.0.1`, and settings that expose a port externally emit a warning |
| Secrets | Passwords and key contents are never written to the log. Host names and user names are |
| Permissions | A warning is emitted when the config file is writable by other users |
| Idempotency | `start` / `stop` converge on the same result regardless of the current state |

---

## 12. Future extensions (out of scope for v1.0)

- Support for remote forwarding (`-R`) and dynamic forwarding (`-D`, SOCKS)
- Grouping entries and bulk operations by tag (`pfwd start @prod`)
- Notification hooks on disconnect / recovery (running an arbitrary command, Slack notifications, etc.)
- Immediate reconnection triggered by detecting network changes (Wi-Fi switch, wake from sleep)
- Statistics of connection history and uptime (`pfwd stats`)
- Shell completion (bash / zsh)
- Referencing encrypted secrets from the config file

---

## 13. Decisions

The points where the design could have gone either way were settled as follows (2026-09-08).

| Item | Decision |
| --- | --- |
| Command name | `pfwd` |
| How to obtain `yq` | Out of scope for this design. Assumed to be installed and on `PATH` |
| Daemon model | Adopt a daemon that manages all entries centrally |
| Default check method | The default `check_mode` is `remote` (an actual reachability check) |
| launchd support on macOS | Not in scope. Service registration is Linux (systemd) only |
