# CLAUDE.md

Guide for working in this repository.

## Project Overview

`pfwd` — a single-file bash script that keeps SSH local port forwards (`ssh -L`) permanently alive.
A daemon periodically health-checks the entries defined in the config file and reconnects with
exponential backoff when a forward goes down.
Runs on both Linux (RedHat family) and macOS.

## File Layout

```
pfwd                     Main script (single file, executable, ~2900 lines)
install.sh               `curl | bash` installer (must run on bash 3.2)
aqua.yaml                Test toolchain (managed by aqua, bats-core)
IDEA.md                  Original requirements memo (Japanese)
README.md / README_ja.md User-facing README
docs/
├── SPECS_ja.md          External design doc (CLI, config file, output, exit codes)
├── SPECS.md             English translation of the above
└── DESIGN_ja.md         Internal design doc (implementation policy, data model, module design)
test/
├── helper.bash          Common bats setup (pfwd)
├── helper_install.bash  Common bats setup (install.sh)
├── fixtures/*.yaml      Config files for tests
├── fixtures/*.json      GitHub API responses for install.sh tests
└── test_*.bats          bats tests
```

## Handling Documentation ★Important

- **For any document that has a `*_ja.md` (Japanese) version, the Japanese version is authoritative.**
- The English versions (`SPECS.md`, `README.md`, etc.) are **translations of the Japanese versions
  intended for publication**, and are subordinate to them.
- When updating documentation, **always edit the Japanese version first**, then reflect the change
  into the English translation. Never edit an English version alone.
- `docs/DESIGN_ja.md` (internal design doc) currently has no English version.
- When the specification changes, update `docs/SPECS_ja.md` → `docs/SPECS.md`, and if needed
  `README_ja.md` → `README.md`, in that order.
  When the implementation policy changes, update `docs/DESIGN_ja.md`.

### Language per Target

| Target | Language |
| --- | --- |
| Source comments in `pfwd` / `install.sh` | English |
| Comments in `test/` | Japanese |
| User-facing output and error messages | English |
| Commit messages | English (Conventional Commits + trailing emoji. e.g. `feat(cli): add status 🚀`) |

## Development Commands

```bash
bats test/                                  # Unit tests
PFWD_IT=1 bats test/test_integration.bats   # Integration tests (requires sshd on localhost + key auth + python3)
shellcheck -x -s bash pfwd install.sh       # Static analysis (keep at zero findings)
bash -n pfwd                                # Syntax check
/bin/bash -n install.sh                     # Syntax check with the bash 3.2 that install.sh has to run on
```

Test tooling is managed with [aqua](https://aquaproj.github.io/) (`aqua.yaml`).

## Architecture

### Single-File Structure

`pfwd` implements every feature in one file so that distribution is just a copy of a single file.
The file is organized into the sections below, in this order, and each block is folded with
`#{{{` … `#}}}` (see `docs/DESIGN_ja.md` 3.1 for details).

```
global variables → common functions (__*) → utility → logging → config
→ state → ssh session → health check → daemon → usage/help → subcommand (_cmd_*)
→ argument parsing → main
```

There is a guard for bats sourcing immediately before the main processing.

```bash
[[ -n "$PFWD_SOURCE_ONLY" ]] && return 0
```

Tests load only the function definitions with `PFWD_SOURCE_ONLY=1 source ./pfwd`, then replace
`_ssh_*` / `_health_check` and friends with stubs for verification.
Sourcing must always happen at file scope so that associative arrays do not become local variables
(see `test/helper.bash`).

### Installer (`install.sh`)

`install.sh` is fetched and piped into bash (`curl -fsSL .../install.sh | bash`), which means it
runs under whatever `/bin/bash` the user has — **on macOS that is 3.2**. None of the bash 4
features `pfwd` itself depends on (associative arrays, `declare -g`, `${var^^}`,
`printf '%(%s)T'`) may be used in this file. Verify with `/bin/bash -n install.sh` on macOS.

- `main "$@"` is on the very last line, so a truncated download executes nothing.
- It installs the tag of the latest GitHub release. **There is deliberately no fallback to `main`**;
  installing an unreleased commit has to be opted into with `PFWD_VERSION=main`.
- Destination defaults: Linux `/usr/local/bin`, macOS `~/.local/bin`. `PFWD_INSTALL_DIR` overrides
  it; there is no command-line argument parsing, since environment variables are what survive a pipe.
- Missing dependencies are warnings only and never abort the install.
- The same bats-sourcing guard as `pfwd`, keyed off `PFWD_INSTALL_SOURCE_ONLY`
  (see `test/helper_install.bash`).

### Runtime Layout

Under `_RUN_DIR` (default in user mode: `${XDG_RUNTIME_DIR}/port-forwarder`) live
`daemon.pid` / `daemon.lock/` (mutual exclusion via the atomicity of mkdir) / `daemon.meta` /
`state/<name>.state` (written by the daemon) / `state/<name>.desired` (written by the CLI) /
`ctl/<name>.sock` (ControlPath) / `err/<name>.err`.
Directories are 0700 and files are 0600 (`umask 077`).

### Key Design Decisions

- **bash 4.2 or later is required** (uses associative arrays and `declare -g`). It does not run on
  the 3.2 bundled with macOS and exits with exit code 7. `install.sh` is the one exception — see
  above.
- Config and state are held in associative arrays; array elements are separated by `_US` (`$'\x1f'`).
- Use the exit-code constants from SPECS chapter 7 (`_EXIT_OK`=0 / `_EXIT_ERROR`=1 / `_EXIT_USAGE`=2 /
  `_EXIT_CONFIG`=3 / `_EXIT_CONNECT`=4 / `_EXIT_NO_DAEMON`=5 / `_EXIT_RUNNING`=6 / `_EXIT_DEPS`=7);
  never hard-code the numbers.

## Coding Conventions

`docs/DESIGN_ja.md` chapter 2 is authoritative. The key points are below.

| Item | Convention |
| --- | --- |
| Naming | Common-infrastructure functions and variables start with `__`; ones specific to this script start with `_`. Variables use upper snake case |
| Local variables | Always declare with `local` inside functions |
| `set -e` / `set -u` | **Do not use.** Express failures via return values and always check them at the call site |
| Return values | Success = 0 / failure = 1 or greater. Functions returning a boolean are named `_is_*` / `_has_*` |
| Standard output | Functions that return a value print only the result to stdout. User-facing output goes through `__show_*` / `_show_result`, logs through `_log_*`; never mix them |
| Error messages | Consolidate the definitions into `_err_*` functions (state what / why / how to fix) |
| External commands | Avoid launching them inside the daemon loop as much as possible. Prefer built-ins such as `printf '%(%s)T'`, `/dev/tcp`, and `[[ ]]` |
| ssh arguments | Do not concatenate strings; push them onto an array (`_SSH_ARGS`) and expand with `"${ARR[@]}"` |
| Colors | Use `C_GREEN` / `C_YELLOW` / `C_RED` / `C_GREY` / `C_OFF` as defined by `__setup_color` (raw ANSI SGR; do not use `tput`) |
| Result display | Per-entry success/failure goes through a single `_show_result <OK|FAILED|WARN|SKIP> <NAME> <MESSAGE>` (to match the `[  OK  ]` notation in SPECS 6.3) |
| Indentation | 2 spaces, no tabs. Put a vim modeline at the end of the file |
| Static analysis | Keep shellcheck at zero findings. Keep suppressions to a minimum and always add a comment explaining why |

<!-- vim: set ts=2 sw=2 sts=2 et nu : -->
