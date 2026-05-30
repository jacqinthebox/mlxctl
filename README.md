# mlxctl

Bash CLI to manage [`mlx_lm.server`](https://github.com/ml-explore/mlx-lm) instances as `launchd` user agents on macOS.

## What it does

- Stores per-server config in `~/.config/mlxctl/servers.json` (name, model, port, host, extra args).
- Generates a `launchd` plist per server (`RunAtLoad=true`, `KeepAlive=true`).
- Bootstraps it into `gui/$UID`.

## Requirements

- macOS (Linux and Windows are not supported)
- `mlx-lm` (`pip install mlx-lm`)
- `jq` (`brew install jq`)
- `bash` 3.2+ (matches the macOS system version)

## Install

```bash
git clone https://github.com/jacqinthebox/mlxctl.git
cd mlxctl
./install.sh
```

`install.sh` symlinks `bin/mlxctl` into `~/.local/bin/mlxctl`. Add `~/.local/bin` to `PATH` if it isn't already:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

## Quickstart

```bash
mlxctl init

mlxctl add qwen  --model mlx-community/Qwen3-Coder-Next-4bit   --port 8081
mlxctl add gemma --model mlx-community/gemma-4-26b-a4b-it-4bit --port 8082

mlxctl start qwen
mlxctl start gemma

mlxctl list
# NAME    MODEL                                          PORT   STATUS
# ----    -----                                          ----   ------
# qwen    mlx-community/Qwen3-Coder-Next-4bit            8081   running
# gemma   mlx-community/gemma-4-26b-a4b-it-4bit          8082   running

curl http://127.0.0.1:8081/v1/models
curl http://127.0.0.1:8082/v1/models
```

## Commands

### Config

| Command | Effect |
|---|---|
| `mlxctl init` | Create `~/.config/mlxctl/servers.json`. |
| `mlxctl add <name> --model M --port P [--host H] [--bin PATH] [-- EXTRA_ARGS...]` | Add a server entry. |
| `mlxctl remove <name>` | Stop the server and remove its entry. |
| `mlxctl list` | List configured servers with running status. |
| `mlxctl edit` | Open the config file in `$EDITOR`. |
| `mlxctl plist <name>` | Print the generated plist. |

### Lifecycle

| Command | Effect |
|---|---|
| `mlxctl start <name>` | Install plist and bootstrap. Server runs immediately and autostarts at login. |
| `mlxctl stop <name>` | Bootout and remove plist. |
| `mlxctl restart <name>` | `stop` then `start`. Required after editing config. |
| `mlxctl status [name]` | Without name: same as `list`. With name: full `launchctl print` output. |
| `mlxctl logs <name> [-f]` | Tail stdout and stderr. |

### Metrics

| Command | Effect |
|---|---|
| `mlxctl ps` | Per-server PID, CPU%, RSS, uptime. One-shot. |
| `mlxctl top [-n SECS]` | Same as `ps`, refreshing every N seconds (default 2). Ctrl+C to exit. |

Other sources:

- Per-request tokens/sec and prompt/decode timings: `mlxctl logs <name> -f`. `mlx_lm.server` prints these at INFO.
- System GPU / ANE / power: `asitop` (`brew install asitop`).
- GUI: Activity Monitor > View > GPU History.

### Chat UI

| Command | Effect |
|---|---|
| `mlxctl chat [--port N] [--no-open]` | Serves a static web chat at `http://127.0.0.1:7780`. Picks a configured endpoint, streams responses, renders `reasoning` blocks, shows TTFT and tokens/sec. |

Static HTML and JS served via Python's `http.server`. The browser talks to MLX directly with no proxy. Requires `python3` (bundled with macOS).

### Integrations

#### Omegon

[Omegon](https://github.com/styrene-lab/omegon) is a Rust agent harness with an OpenAI-compatible client. Any mlxctl endpoint works as an Omegon backend via the `openai` provider, using the full HuggingFace repo id as the model name.

| Command | Effect |
|---|---|
| `mlxctl omegon` | List configured endpoints with their Omegon model id (`openai:<model>`). |
| `mlxctl omegon <name>` | Print `export OPENAI_BASE_URL=...` and `OPENAI_API_KEY=dummy` on stdout. Print TUI commands on stderr. |
| `mlxctl omegon <name> --slash` | Print only the Omegon TUI slash commands. |

Usage:

```bash
eval "$(mlxctl omegon qwen)"
omegon
# inside the TUI:
#   /login openai              # paste 'dummy' as the API key
#   /model openai:mlx-community/Qwen3-Coder-Next-4bit
```

Three gotchas:

1. **`OPENAI_BASE_URL` must not include `/v1`.** Omegon's OpenAI client appends `/v1/chat/completions` itself. A `/v1` suffix produces `/v1/v1/chat/completions` (404). `mlxctl omegon` strips it.
2. **`OLLAMA_HOST` overrides provider selection.** If exported in the shell, Omegon defaults to the Ollama provider and sends Ollama-style names like `gemma4:26b`. MLX rejects these because HuggingFace repo ids cannot contain `:`. `mlxctl omegon` unsets it.
3. **Reasoning models return empty `content` by default.** Gemma 4, DeepSeek-R1, and Qwen3-Thinking emit chain-of-thought in `message.reasoning`. Omegon's OpenAI client only renders `content`. At `mlx_lm.server`'s default `max_tokens=512`, the model often exhausts the budget inside `reasoning` and `content` stays empty. Two workarounds:

   - **Disable thinking on the server.** Add to the model's `extraArgs`:
     ```json
     "extraArgs": ["--chat-template-args", "{\"enable_thinking\":false}"]
     ```
     Then `mlxctl restart <name>`. Verify:
     ```bash
     curl -sS -X POST http://127.0.0.1:8082/v1/chat/completions \
       -H 'Content-Type: application/json' \
       -d '{"model":"<id>","messages":[{"role":"user","content":"say hi"}],"max_tokens":50}'
     ```
   - **Raise `max_tokens`.** Add `--max-tokens 4096` to `extraArgs`. `content` stays empty in Omegon (its client still doesn't read `reasoning`) but reasoning-aware clients see the full trace.

   Qwen3-Coder is not a reasoning model and works without flags.

##### Reasoning models under MLX vs Ollama

Reasoning models wrap chain-of-thought in `<think>...</think>` before the final answer. Servers handle the tags differently:

| Server | `<think>` handling |
|---|---|
| Ollama | Merges thought and answer into `message.content`, or strips `<think>` entirely, depending on the model. |
| `mlx_lm.server` | Puts chain-of-thought in `message.reasoning`, final answer in `message.content`. |

`mlx_lm.server`'s default `--max-tokens` is 512. When reasoning fills the budget, the response ends with `finish_reason: "length"`, `reasoning` populated, `content` empty.

Two ways to recover `content`:

- `chat_template_kwargs: {"enable_thinking": false}`, either in server args (above) or per request. Honored by Gemma 4 and Qwen3 via their chat templates. No tokens are spent on reasoning.
- Raise `max_tokens` and accept the extra inference cost.

## Config file

`~/.config/mlxctl/servers.json`:

```json
{
  "servers": [
    {
      "name": "qwen",
      "model": "mlx-community/Qwen3-Coder-Next-4bit",
      "port": 8081,
      "host": "127.0.0.1",
      "extraArgs": []
    },
    {
      "name": "gemma",
      "model": "mlx-community/gemma-4-26b-a4b-it-4bit",
      "port": 8082,
      "host": "127.0.0.1",
      "extraArgs": ["--chat-template-args", "{\"enable_thinking\":false}"]
    }
  ]
}
```

Per-server fields:

| Field | Default | Notes |
|---|---|---|
| `host` | `127.0.0.1` | Bind address. Use `0.0.0.0` for LAN. |
| `bin` | auto-detected | Override path to `mlx_lm.server`. |
| `extraArgs` | `[]` | Passed verbatim to `mlx_lm.server`. |

Edit with `mlxctl edit`, then `mlxctl restart <name>`.

## Paths

| Thing | Location |
|---|---|
| Config | `~/.config/mlxctl/servers.json` |
| Plists | `~/Library/LaunchAgents/dev.local.mlxctl.<name>.plist` |
| Logs | `~/Library/Logs/mlxctl/<name>.{out,err}.log` |

## How it works

`mlxctl start <name>` writes a `launchd` plist with `RunAtLoad=true` and `KeepAlive=true`, then runs `launchctl bootstrap gui/$UID <plist>`.

Inspect what's loaded:

```bash
launchctl list | grep mlxctl
mlxctl status qwen
```

## Common patterns

### Change a port

```bash
mlxctl edit              # change "port": 8081 to "port": 9090
mlxctl restart qwen
```

### Bind to the LAN

```bash
mlxctl add qwen-lan --model mlx-community/Qwen3-Coder-Next-4bit --port 8080 --host 0.0.0.0
mlxctl start qwen-lan
```

### Use a specific Python environment

```bash
mlxctl add qwen --model mlx-community/Qwen3-Coder-Next-4bit --port 8080 \
  --bin /Users/me/venvs/mlx/bin/mlx_lm.server
```

### Stop everything

```bash
for s in $(jq -r '.servers[].name' ~/.config/mlxctl/servers.json); do
  mlxctl stop "$s"
done
```

## Notes on "OpenAI-compatible"

OpenAI-compatible servers agree on the URL shape and JSON skeleton. Other layers vary.

| Layer | Variation |
|---|---|
| URL shape | Some clients want `OPENAI_BASE_URL=http://host:port`. Others want `.../v1`. Wrong choice produces `404 /v1/v1/chat/completions` or `404 /chat/completions`. |
| Provider selection | Env vars like `OLLAMA_HOST` or `ANTHROPIC_API_KEY` can change which adapter a multi-provider client picks. |
| Model id grammar | Ollama tags use `:` (`gemma4:26b`). HuggingFace repo ids forbid `:` (`mlx-community/gemma-4-26b-a4b-it-4bit`). |
| Auth conventions | OpenAI expects `Authorization: Bearer <key>`. Some local servers accept any non-empty string. A few reject the header. |
| Default knobs | `mlx_lm.server` defaults `max_tokens=512`. Other servers default higher. |
| Response shape | OpenAI's o-series added `message.reasoning`. MLX adopted it for any reasoning-capable model. Ollama merges everything into `content`. |
| Capability detection | Some clients keep a hardcoded allowlist of reasoning model names. Models outside the list have `reasoning` ignored. |
| Chat template semantics | `enable_thinking`, `tools`, `response_format`. Honored by some templates, ignored by others. The same flag can mean different things across models. |
| Streaming format | Ollama uses line-delimited JSON. OpenAI uses Server-Sent Events (`data: {...}\n\n`, terminated by `data: [DONE]`). |
| Tool calling | OpenAI: `tool_calls`. Anthropic: `tool_use` content blocks. Ollama: separate shape. llama.cpp: separate shape. |
| Finish reasons | `stop`, `length`, `end_turn`, `tool_use`, `content_filter`. Overlapping but non-identical vocabularies. |
| Token counting | Input, output, reasoning, cached, reused. Counted and reported differently per provider. |

### Diagnostic notes

- `finish_reason: "length"` with empty `content` means the budget was consumed elsewhere (usually `reasoning`).
- `finish_reason: "stop"` with empty `content` means the client is reading the wrong field.
- The full server response often contains fields the client drops. Inspect with `curl | jq`.

### Gemma case (full instance)

Combination: Gemma 4 emits chain-of-thought, MLX returns it in `message.reasoning`, Omegon reads only `content`, and `max_tokens=512` is below typical reasoning output. Any one of the four can be changed. The sample `servers.json` above ships with the chat-template fix on the server side.

## License

MIT
