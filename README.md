# mlxctl

A tiny CLI to run [`mlx_lm.server`](https://github.com/ml-explore/mlx-lm) instances as managed background services on macOS, using `launchd` under the hood.

Stop typing `mlx_lm.server --model ... --port ...` in three terminals. Just `mlxctl start qwen` / `mlxctl start gemma`.

## Why

- **Persistent**: servers survive terminal close and reboot (proper `launchd` agents).
- **Auto-restart**: if `mlx_lm.server` crashes, `launchd` brings it back.
- **One source of truth**: all your model/port mappings live in `~/.config/mlxctl/servers.json`.
- **Zero runtime overhead**: pure bash + `jq` + macOS built-ins. No daemon of its own.

## Requirements

- macOS (uses `launchd` — Linux/Windows not supported)
- `mlx_lm` (`pip install mlx-lm`)
- `jq` (`brew install jq`)
- `bash` 4+ (macOS ships 3.x; you don't need 4 — the script targets 3.2)

## Install

```bash
git clone https://github.com/jacqinthebox/mlxctl.git
cd mlxctl
./install.sh
```

This symlinks `bin/mlxctl` into `~/.local/bin/mlxctl`. Make sure `~/.local/bin` is on your `PATH`:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

## Quickstart

```bash
# create config dir
mlxctl init

# register two models on two ports
mlxctl add qwen   --model mlx-community/Qwen3-Coder-Next-4bit   --port 8081
mlxctl add gemma  --model mlx-community/gemma-4-26b-a4b-it-4bit --port 8082

# launch them — they're now running and will autostart on next login
mlxctl start qwen
mlxctl start gemma

# verify
mlxctl list
# NAME               MODEL                                          PORT   STATUS
# ----               -----                                          ----   ------
# qwen               mlx-community/Qwen3-Coder-Next-4bit            8080   running
# gemma              mlx-community/gemma-4-26b-a4b-it-4bit          8082   running

# poke them
curl http://127.0.0.1:8080/v1/models
curl http://127.0.0.1:8082/v1/models
```

## Commands

### Config

| Command | What it does |
|---|---|
| `mlxctl init` | Create `~/.config/mlxctl/servers.json` |
| `mlxctl add <name> --model M --port P [--host H] [--bin PATH] [-- EXTRA_ARGS...]` | Add a server |
| `mlxctl remove <name>` | Stop and remove a server |
| `mlxctl list` | List configured servers and their running status |
| `mlxctl edit` | Open the config file in `$EDITOR` |
| `mlxctl plist <name>` | Print the generated `launchd` plist (for debugging) |

### Lifecycle

| Command | What it does |
|---|---|
| `mlxctl start <name>` | Install plist + bootstrap. Server runs now and autostarts at login. |
| `mlxctl stop <name>` | Bootout + remove plist. Stops now, will not autostart. |
| `mlxctl restart <name>` | `stop` + `start`. Useful after editing config. |
| `mlxctl status [name]` | Without name: same as `list`. With name: full `launchctl print` output. |
| `mlxctl logs <name> [-f]` | Tail stdout + stderr. |

### Metrics

| Command | What it does |
|---|---|
| `mlxctl ps` | One-shot table: per-server PID, CPU%, RSS (RAM), uptime. |
| `mlxctl top [-n SECS]` | Same as `ps` but refreshes (default every 2s). Ctrl+C to exit. |

For richer visibility:

- **Per-request tokens/sec**, prompt/decode timings — `mlxctl logs <name> -f` (mlx_lm.server prints these at INFO level)
- **System-wide GPU / ANE / power draw** on Apple Silicon — `brew install asitop` then run `asitop`
- **GUI overview** — Activity Monitor → View → GPU History

### Chat UI

| Command | What it does |
|---|---|
| `mlxctl chat [--port N] [--no-open]` | Serve a single-page web chat at `http://127.0.0.1:7780` (default port). Picks any configured endpoint, streams responses, shows reasoning chain-of-thought for thinking models, displays TTFT and tokens/sec. |

Pure-static HTML + JS — uses Python's built-in `http.server` to serve it. The page talks directly to MLX (no proxy), so it exercises the exact same code path your real client would. Great for diagnosing whether a problem is in *your* client or in MLX itself.

Requires `python3` (built into macOS).

### Integrations

#### Omegon

[Omegon](https://github.com/styrene-lab/omegon) is a Rust agent harness. Its OpenAI client honors `OPENAI_BASE_URL`, so any mlxctl endpoint can drive Omegon — pick the openai provider and use the full HuggingFace repo id as the model.

| Command | What it does |
|---|---|
| `mlxctl omegon` | Lists configured endpoints with their Omegon-ready model id (`openai:<model>`). |
| `mlxctl omegon <name>` | Prints `export OPENAI_BASE_URL=…` / `OPENAI_API_KEY=dummy` on stdout, plus copy-paste TUI commands on stderr. Designed for `eval "$(mlxctl omegon <name>)"`. |
| `mlxctl omegon <name> --slash` | Prints only the Omegon TUI slash commands (`/secrets set`, `/model openai:…`) — paste these inside a running Omegon session. |

Typical flow:

```bash
eval "$(mlxctl omegon gemma)"      # sets OPENAI_BASE_URL and OPENAI_API_KEY
omegon                              # launches with the env in place
# then inside the TUI:
#   /secrets set OPENAI_API_KEY dummy
#   /model openai:mlx-community/gemma-4-26b-a4b-it-4bit
```

> Don't use Omegon's `Ollama (Local)` provider for MLX — that path talks to Ollama's native API on `:11434` and uses Ollama-style model names like `gemma4:26b`, which MLX rejects (HuggingFace repo ids can't contain `:`).

## Config file

`~/.config/mlxctl/servers.json`:

```json
{
  "servers": [
    {
      "name": "qwen",
      "model": "mlx-community/Qwen3-Coder-Next-4bit",
      "port": 8080,
      "host": "127.0.0.1",
      "extraArgs": []
    },
    {
      "name": "gemma",
      "model": "mlx-community/gemma-4-26b-a4b-it-4bit",
      "port": 8082,
      "host": "127.0.0.1",
      "extraArgs": ["--log-level", "INFO"]
    }
  ]
}
```

Optional per-server fields:

| Field | Default | Notes |
|---|---|---|
| `host` | `127.0.0.1` | Bind address. Use `0.0.0.0` to expose on LAN. |
| `bin` | auto-detected | Override path to `mlx_lm.server` (e.g. for a specific venv). |
| `extraArgs` | `[]` | Extra args passed verbatim to `mlx_lm.server`. |

You can edit it directly with `mlxctl edit`, then `mlxctl restart <name>` to apply.

## Paths

| Thing | Location |
|---|---|
| Config | `~/.config/mlxctl/servers.json` |
| Plists | `~/Library/LaunchAgents/dev.local.mlxctl.<name>.plist` |
| Logs | `~/Library/Logs/mlxctl/<name>.{out,err}.log` |

## How it works

Each `mlxctl start <name>` writes a `launchd` plist with `RunAtLoad=true` and `KeepAlive=true`, then `launchctl bootstrap`s it into your user GUI domain (`gui/$UID`). That's it.

To see what's actually loaded:

```bash
launchctl list | grep mlxctl
```

To inspect one in detail:

```bash
mlxctl status qwen
```

## Common patterns

### Switching ports without losing config

```bash
mlxctl edit              # change "port": 8080 to "port": 9090
mlxctl restart qwen
```

### Running on the LAN

```bash
mlxctl add qwen-lan --model mlx-community/Qwen3-Coder-Next-4bit --port 8080 --host 0.0.0.0
mlxctl start qwen-lan
```

### Using a specific Python environment

```bash
mlxctl add qwen --model mlx-community/Qwen3-Coder-Next-4bit --port 8080 \
  --bin /Users/me/venvs/mlx/bin/mlx_lm.server
```

### Stop everything at once

```bash
for s in $(jq -r '.servers[].name' ~/.config/mlxctl/servers.json); do
  mlxctl stop "$s"
done
```

## License

MIT
