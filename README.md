<p align="center">
<img width="70%" src="https://github.com/user-attachments/assets/dab7c553-55ce-45c0-a6bb-b96338d4192d" />
</p>

# Introduction

Personal containerized setup for a fully local AI-agent, no
external API involved.
It wraps [pi](https://pi.dev) as the coding agent and
[RamaLama](https://github.com/containers/ramalama) to serve GGUF models,
plus an automatic parameter-tuning step via
[llama-optimus](https://github.com/BrunoArsioli/llama-optimus).

There's also a small wrapper to install extensions from CLI and a wrapper to start pi and ramalama as an RPC server (to make PI compatible VSCode extensions work out-of-the-box).

I built this mainly for myself — I
wanted a setup that doesn't leave Python, pip, or random wrappers scattered
on the host every time I touch something. If you're in a similar spot, feel free to use it.

---

## Core idea

Anything that doesn't strictly need to run on the host, doesn't. The host
only ever runs `ramalama` itself (which spins the served model up in its
own container) and the OCI engine (Podman or Docker). The coding agent,
the benchmarking step, and even the parsing of the benchmark output all
run isolated — no `git clone` or `pip install` ever touches the host
directly, no python dependencies and executables on the host except for ramalama.

```
┌──────────────────────────── ai-net (bridge) ─────────────────────────────┐
│                                                                          │
│   ramalama                                                               │
│     - CLI process on the host, talks to the other services over the      │
│       bridge network; not managed by compose.yaml                        │
│     - serves the GGUF model on http://ramalama:$MODEL_PORT               │
│                                                                          │
│   pi-agent (compose service)                                             │
│     - coding agent, TUI or RPC                                           │
│     - reaches the model at LLM_ENDPOINT=http://ramalama:$MODEL_PORT/v1   │
│                                                                          │
│   llama-optimus (compose service, "benchmark" profile, runs on-demand)   │
│     - works out optimal batch size / tensor overrides for a model        │
│     - uses a llama-bench binary copied byte-for-byte from the ramalama   │
│       container at build time (COPY --from), nothing mounted or proxied  │
│     - its output is parsed by a second, throwaway container from the     │
│       same image                                                         │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘

Scripts and config files short description:
  pi-ramalama              → CLI arguments dispatcher, it's the main executable
  lib/*.sh, lib/*.py     → the actual logic, one module per responsibility
  conf/env.conf            → project variables defaults, don't edit
  conf/user.env.conf        → your own values, override env.conf
  conf/pi-mounts.conf         → extra bind mount points for pi-agent (optional)
  conf/pi-extensions.conf      → commands to run inside pi-agent (mainly for managing extensions, runs on-demand)
```

---

## Repo layout

| File | Role |
|---|---|
| `ai-agent` | Dispatcher: reads the arguments, sources `lib/*.sh`, calls the right function |
| `lib/common.sh` | Detects the engine (Podman/Docker), the `compose()` wrapper, resolves `ramalama` in PATH, renders extra mounts |
| `lib/env.sh` | Idempotent bootstrap (`ensure_environment`) and destructive teardown (`remove_env`) |
| `lib/extensions.sh` | Runs `conf/pi-extensions.conf` inside `pi-agent` |
| `lib/model.sh` | Model lifecycle: pull, benchmark, remove, update saved params |
| `lib/session.sh` | Session lifecycle: TUI startup, RPC start/stop |
| `lib/pi-wrapper.sh.tmpl` | Template for the host→container `pi` proxy, rendered by `ensure_environment()` |
| `lib/parse_benchmark.py` | Extracts `Best config: {...}` from `optimus.py`'s output. Runs **inside** the container, never on the host |
| `conf/env.conf` | Project defaults — don't edit this one directly |
| `conf/user.env.conf` | Your personal overrides (ports, CPU/RAM budget, RamaLama images, per-model params). Start from `conf/user.env.conf.example` |
| `conf/pi-mounts.conf` | Extra mounts for `pi-agent`, one per line. Start from `conf/pi-mounts.conf.example` |
| `conf/pi-extensions.conf` | Commands to install extensions inside `pi-agent`. Start from `conf/pi-extensions.conf.example` |
| `conf/models.conf` | Auto-generated — holds the per-model params discovered by pull/benchmark, don't hand-edit |
| `pi-dev/Dockerfile` | `pi-sandbox-image` (Node 24 + `pi-coding-agent` + toolchain) |
| `optimus/Dockerfile` | `llama-optimus-sandbox`: pinned clone + isolated Python deps + `llama-bench` copied from the ramalama container |
| `compose.yaml` | The `pi-agent` and `llama-optimus` services |

---

# Setup

## Prerequisites

- `podman` (preferred) or `docker` + `docker compose`
- `pip` or `pipx` required for ramalama (Python 3.9 or later)
- `ramalama` CLI on the host — it's the orchestrator for the
  model container, so it has to be a real host binary, not itself
  containerized
- `curl`, used by the healthchecks

Every time pi-ramalama is executed it will perform a dependency check — it only
checks and prints what's missing (and how to install it), it never
installs anything for you.
---


## Quick start

```bash
git clone <this-repo>
cd pi-dev-ramalama-docker
chmod +x pi-ramalama lib/*.sh

cp conf/user.env.conf.example conf/user.env.conf
# fill in conf/user.env.conf

# optional
cp conf/pi-mounts.conf.example conf/pi-mounts.conf
cp conf/pi-extensions.conf.example conf/pi-extensions.conf

./pi-ramalama --setup
./pi-ramalama --pull hf://Jackrong/Qwopus3.5-9B-Coder-GGUF:IQ4_XS # Example
./pi-ramalama --install-extensions   # if you filled in pi-extensions.conf
./pi-ramalama --start
```

---


## Configuration

### `conf/user.env.conf`

Copy `conf/user.env.conf.example` and fill it in — this is where all the
machine-specific values live:

`conf/env.conf` holds the project's own defaults (ports, timeouts) and
shouldn't be touched — override values through `user.env.conf` instead.

### `conf/pi-mounts.conf`

One mount per line in standard compose syntax:

```
HOST_PATH:CONTAINER_PATH[:OPTIONS]
```

The base mounts (`pi-agent`'s home, `settings.json`, the extensions
volume) already live in `compose.yaml` — this file is only for extra,
machine-specific ones (extra skill packs, extension files, shared caches). It's re-rendered automatically on
every `--setup`/`--start`, or manually with `./pi-ramalama --render-mounts`.

### `conf/pi-extensions.conf`

One full shell command per line, run in order inside `pi-agent` image with a
TTY attached (thought for extension's interactive installations):

```bash
./pi-ramalama --install-extensions
```

> Note: Run this only after the mounts are in place — otherwise an extension
> writing to a path you just added in `pi-mounts.conf` ends up in the
> container's ephemeral layer instead of the actual mount.

---

# Usage

## Available Commands

```bash
./pi-ramalama --setup
```
Host bootstrap: creates the needed directories (`~/.pi/agent`, etc.), generates the `~/.local/bin/pi` wrapper from
`lib/pi-wrapper.sh.tmpl`, builds `pi-sandbox-image` if it's missing, and
renders the mounts.

> Every `ai-agent` command, not just `--setup`, starts by checking for
> an OCI engine, `ramalama`, and `curl` on the host. If any is missing
> it prints what to install and exits — it never installs anything on
> your behalf.

```bash
./pi-ramalama --start
```
Startup flow: bootstrap (same as `--setup`), lists the models
available in RamaLama and asks which one to run, starts `ramalama serve`
with that model's saved params, waits for the healthcheck (configurable
timeout, 60s by default), starts `pi-agent`, and attaches in TUI. RPC mode is handled separately, see
below.

```bash
./pi-ramalama --pull <model_uri>
```
Downloads a model with `ramalama pull`, then asks whether to run the
isolated benchmark to work out optimal params. If you say no, or the
benchmark fails, it still saves a fallback params entry instead of
leaving the model with no setting at all.

```bash
./pi-ramalama --benchmark [model_uri|index]
```
Benchmark only (no pull) on a model that's already been downloaded.

```bash
./pi-ramalama --rm-model
```
Lists installed models, removes the one you pick, and clears its saved
params entry from `conf/models.conf`.

```bash
./pi-ramalama --start-rpc / --start-rpc-async / --stop-rpc
```
Used internally by the `pi --mode rpc` wrapper (see below) — you normally
won't call these by hand.

```bash
./pi-ramalama --render-mounts
./pi-ramalama --install-extensions
./pi-ramalama --remove   # tears down containers, volumes, and images
```

---

# Feature description

## The `pi` wrapper for VSCode / RPC

`ensure_environment()` generates `~/.local/bin/pi`. It's not the real `pi`
binary — it's a proxy that decides what to do based on the arguments:

| Invocation | What happens |
|---|---|
| `pi` (no arguments) | Runs `pi-ramalama --start` — the full interactive TUI flow |
| `pi --version [...]` | Forwarded to the real binary, reusing `pi-agent` if it's already up |
| `pi --mode rpc [...]` | Auto-bootstraps if needed, then attaches |

### `pi --mode rpc` working principles
Once it attaches, the wrapper's stdout becomes the RPC transport VSCode reads as JSON frames.
Every bootstrap message goes to stderr instead — anything that leaks
onto stdout before the attach corrupts the framing.

The wrapper waits for `pi-agent` to be running (a few seconds), but it
deliberately does *not* wait for the model to finish loading — Pi's RPC
server attaches fine before a model is ready, it only needs one once the
first prompt actually goes out. `DEFAULT_RPC_MODEL` starts in the
background and the wrapper moves on immediately. If you'd rather avoid
any delay on that first prompt, run `./pi-ramalama --start-rpc` ahead of
time (blocking, waits for the model).

If `ramalama` is already running with any model, the wrapper leaves it
alone. When an RPC session ends, `stop_rpc` waits a few seconds and only
stops `ramalama`/`pi-agent` if no other RPC session picked up in the
meantime (e.g. a quick VSCode window reload).

---

## How the isolated benchmarking works

1. `benchmark()` in `lib/model.sh` works out the model's path on the host
   — it `find`s `~/.local/share/ramalama/store` for a file matching the
   model's basename (one match: used directly; several: pick from a
   list; none: falls back to asking for the path) — and the path the
   container will see.

2. It runs `compose --profile benchmark run --rm llama-optimus --model <path>`

3. The `llama-optimus-sandbox` container runs `optimus.py`, which in turn
   calls `llama-bench` — the exact same binary as the one in the
   `ramalama` container, copied at build time (`COPY --from`).

4. The text output (`Best config: {...}`) is piped over stdin into a
   second, throwaway container from the same service, 
   with `lib/parse_benchmark.py` mounted read-only.

5. The extracted params get written to `conf/models.conf`


> Note: `key_map` in `lib/parse_benchmark.py` is empty by default (it
> falls back to uppercasing the param name). If `optimus.py` returns keys
> that don't map cleanly to `LLAMA_ARG_<KEY>`, add an explicit exception
> there.
---

## Podman / Docker

The script detects whichever engine is available, Podman by default,
Docker as a fallback (`podman-compose` vs `docker compose`).
Both read the same `compose.yaml`

---

# TODO list

- The npm versions pinned in `pi-dev/Dockerfile` are still `latest`;
  worth pinning explicit versions for reproducible builds
- `--profile` in compose needs `docker compose` v2+ or a recent
  `podman-compose`
- Write an install-script with a pinned ramalama version
- Make the wrapper dependecy free on the host except for Docker/Podman
- Ensure correct device (GPU) pass-through also for llama-optimus container

# Links and contribution
This small project wouldn't be possible without:
- [ramalma](https://github.com/containers/ramalama)
- [llama-optimus](https://github.com/BrunoArsioli/llama-optimus)
- [llama-cpp](https://github.com/ggml-org/llama.cpp)
- [pi.dev](https://github.com/earendil-works/pi/tree/main)

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
