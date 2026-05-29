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
eval "$(mlxctl omegon qwen)"        # sets OPENAI_BASE_URL (host only — no /v1!),
                                    # OPENAI_API_KEY=dummy, and unsets OLLAMA_HOST
omegon                              # launches with the env in place
# then inside the TUI:
#   /login openai                   # paste 'dummy' as the API key
#   /model openai:mlx-community/Qwen3-Coder-Next-4bit
```

Three gotchas worth knowing:

1. **Don't include `/v1` in `OPENAI_BASE_URL`** — omegon's OpenAI client appends `/v1/chat/completions` itself, so a `/v1` suffix yields `/v1/v1/...` → 404. `mlxctl omegon` strips it for you.
2. **Unset `OLLAMA_HOST`** — if you have it exported in your shell, omegon picks the Ollama provider by default (and sends Ollama-style names like `gemma4:26b` which MLX rejects, because HuggingFace repo ids can't contain `:`). `mlxctl omegon` unsets it for you.
3. **Reasoning models appear "silent"** — Gemma 4, DeepSeek-R1, Qwen3-Thinking etc. emit their chain-of-thought in `message.reasoning` / `delta.reasoning`. Omegon's OpenAI-compatible client only renders `content`, and at omegon's default `max_tokens` the model often exhausts the budget mid-thought, leaving `content` empty → blank bubble. Two fixes:

   - **Disable thinking on the server** (recommended for chat). Add this to the model's `extraArgs`:
     ```json
     "extraArgs": ["--chat-template-args", "{\"enable_thinking\":false}"]
     ```
     Then `mlxctl restart <name>`. Gemma 4 / Qwen3 will answer directly with no `<think>` block. Verify with a 50-token probe:
     ```bash
     curl -sS -X POST http://127.0.0.1:8082/v1/chat/completions \
       -H 'Content-Type: application/json' \
       -d '{"model":"<id>","messages":[{"role":"user","content":"say hi"}],"max_tokens":50}'
     ```
   - **Leave thinking on, but raise the budget** if you want the reasoning visible elsewhere (e.g. mlxctl's chat UI, which renders `reasoning`). Pass `--max-tokens 4096` (default is 512) in `extraArgs`. Note: omegon will still show a blank bubble unless its client learns to read `reasoning`.

   Qwen3-Coder is a non-reasoning model — works out of the box, no flags needed.

##### Why reasoning models go silent in OpenAI-compatible clients

Reasoning models like Gemma 4, DeepSeek-R1, and Qwen3-Thinking are trained to emit a chain-of-thought between `<think>...</think>` tags before their final answer. Different servers handle those tags differently:

| Server | `<think>` handling | Net effect |
|---|---|---|
| **Ollama** | Merges thought + answer into a single `message.content` string (or strips `<think>` blocks entirely for some models) | Any OpenAI-compatible client sees a normal response. Works everywhere. |
| **mlx_lm.server** | Splits them — chain-of-thought goes into a separate `message.reasoning` field, only the final answer goes into `message.content` | Clients that read `content` only see whatever the model wrote *after* `</think>`. If the budget runs out first, `content` is empty. |

That's why the same Gemma 4 model "worked in Ollama" but appears silent through MLX+omegon. It's not the model, it's the response shape.

`mlx_lm.server`'s default `--max-tokens` is **512** — generous for a non-reasoning model, tiny for one that spends 200–800 tokens on hidden thinking before saying "Hi". When the budget runs out mid-thought, MLX returns `finish_reason: "length"`, `reasoning` populated, `content: ""`. Omegon dutifully renders the empty string.

Two ways out:

- **Server-side off switch (`enable_thinking:false`)**. The chat template for Gemma 4 and Qwen3 honours this flag — when set, the template skips the `<think>` injection entirely and the model behaves like a plain chat model. This is the simplest fix for any OpenAI-compatible client that doesn't speak the `reasoning` field. It's also the cheapest at inference time (no wasted tokens).
- **Per-request override**. The same flag can be sent per request as `chat_template_kwargs: {"enable_thinking": false}` in the JSON body. Useful if you want one server that some clients use with thinking on (mlxctl chat UI shows the reasoning trace) and others without.

Once omegon learns to render `delta.reasoning` / `message.reasoning`, neither workaround will be needed. Until then, server-side off is the path of least surprise.

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
      "extraArgs": ["--chat-template-args", "{\"enable_thinking\":false}"]
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

## Field notes on "OpenAI-compatible"

If you're new to running local LLMs and shuttling them between clients (chat UIs, agents, editors), the most useful thing to internalize early is this:

> **"OpenAI-compatible" means the URL and the JSON skeleton match. Nothing else is guaranteed.**

Every layer below the wire format drifts between implementations. None of these layers is wrong on its own — they each made a reasonable local choice — but stacking them creates booby traps. Some of them you'll only discover by getting bitten.

### Layers that drift

| Layer | Where it bites |
|---|---|
| **URL shape** | Some clients want `OPENAI_BASE_URL=http://host:port`, some want `…/v1`. Get it wrong and you see `404 /v1/v1/chat/completions`. |
| **Provider selection** | Env vars like `OLLAMA_HOST` or `ANTHROPIC_API_KEY` can silently change which adapter a multi-provider client picks. Look at the actual footer/status before debugging the wire. |
| **Model id grammar** | Ollama tags use `:` (`gemma4:26b`). HuggingFace repo ids forbid `:` (`mlx-community/gemma-4-26b-a4b-it-4bit`). Servers usually reject the wrong shape with terse errors. |
| **Auth conventions** | OpenAI wants `Authorization: Bearer <key>`. Some local servers want any non-empty string ("dummy" works). A few want no header at all and reject if you send one. |
| **Default knobs** | `mlx_lm.server` defaults `max_tokens=512`. Some servers default to a few thousand. A reasoning model on the low default goes silent. |
| **Response shape extensions** | OpenAI added `message.reasoning` for o-series. MLX adopted it for any reasoning-capable model. Ollama merges everything into `content`. Clients that predate the extension only read `content` → blank bubbles. |
| **Capability detection** | Some clients keep a hardcoded allowlist of "reasoning models." If your model name isn't on the list, the reasoning field is silently dropped even when it's right there in the response. |
| **Chat template semantics** | `enable_thinking: false`, `tools: [...]`, `response_format: {...}` — each is honored by some templates and ignored by others. The same flag can mean different things across models. |
| **Streaming format** | Ollama is line-delimited JSON. OpenAI is Server-Sent Events (`data: {...}\n\n` framing, `data: [DONE]` terminator). They're not interchangeable even though both ship JSON over HTTP. |
| **Tool calling** | OpenAI uses `tool_calls` arrays. Anthropic uses `tool_use` content blocks. Ollama has its own shape. llama.cpp has yet another. None map cleanly. |
| **Stop / finish reasons** | `"stop"`, `"length"`, `"end_turn"`, `"tool_use"`, `"content_filter"` — overlapping vocabularies with non-identical meanings. |
| **Token counting** | Input / output / reasoning / cached / reused — every provider counts and reports differently. Bills and rate limits diverge accordingly. |

### Survival kit

1. **Probe every new endpoint with `curl` before pointing a real client at it.** Five minutes of `curl … | jq` saves an hour of "why is my UI broken." Always print the full response shape, not just `content` — that's how you spot `reasoning`, `tool_calls`, refusals, and other fields a client might be silently dropping.
2. **When something "doesn't answer," check `finish_reason` first.** `"length"` with empty `content` means the model exhausted the budget on something invisible (reasoning, tools, formatting). `"stop"` with empty `content` means you're parsing the wrong field.
3. **Trust the server's logs, not your client's UI.** A 200 OK with a blank UI bubble is a parser problem on the client side, not a model problem. The wire trace doesn't lie.
4. **Treat each model + server + client triplet as its own configuration.** "Qwen on MLX with omegon" and "Gemma on MLX with omegon" are different setups with different defaults and different bugs. Don't assume a fix for one carries over.
5. **The 9pm-Friday debugging session is the standard onboarding ritual.** Everyone who knows this ecosystem learned it the same way. There is no comprehensive tutorial because the ecosystem moves faster than anyone can write one.

### Worked example: the Gemma blank-bubble episode

The "Reasoning models appear silent" gotcha and "Why reasoning models go silent" deep-dive above walk through one full instance of these layers colliding: Gemma 4 (model thinks before answering) + MLX (splits thinking into a separate field) + omegon (only reads `content`, doesn't recognize Gemma as a reasoning model) + `max_tokens=512` default (thinking exhausts the budget). Pull on any one of those four threads and the bug disappears. We pulled on the chat template (`enable_thinking:false`). Equally valid would have been raising `max_tokens`, switching client, or switching server. Knowing which thread to pull is the skill.

## License

MIT
