# mlxctl

A small bash CLI to run [`mlx_lm.server`](https://github.com/ml-explore/mlx-lm) instances as `launchd` user agents on macOS.

It replaces ad-hoc `mlx_lm.server --model ... --port ...` invocations with named, persistent services: `mlxctl start qwen`, `mlxctl start gemma`.

## What it does

- Writes a `launchd` plist per server (`RunAtLoad=true`, `KeepAlive=true`).
- Bootstraps it into the user GUI domain (`gui/$UID`).
- Tracks server name, model, port, host, and optional extra args in `~/.config/mlxctl/servers.json`.

That's the whole product. No daemon, no dependencies beyond `bash`, `jq`, and `mlx-lm`.

## Requirements

- macOS (uses `launchd`; Linux/Windows are not supported)
- `mlx-lm` (`pip install mlx-lm`)
- `jq` (`brew install jq`)
- `bash` (the script targets 3.2, which is what macOS ships)

## Install

```bash
git clone https://github.com/jacqinthebox/mlxctl.git
cd mlxctl
./install.sh
```

`install.sh` symlinks `bin/mlxctl` into `~/.local/bin/mlxctl`. Make sure `~/.local/bin` is on `PATH`:

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
| `mlxctl list` | List configured servers with their running status. |
| `mlxctl edit` | Open the config file in `$EDITOR`. |
| `mlxctl plist <name>` | Print the generated plist (for debugging). |

### Lifecycle

| Command | Effect |
|---|---|
| `mlxctl start <name>` | Install plist + bootstrap. Server runs now and autostarts at login. |
| `mlxctl stop <name>` | Bootout and remove plist. No autostart. |
| `mlxctl restart <name>` | `stop` + `start`. Use after editing config. |
| `mlxctl status [name]` | Without name: same as `list`. With name: full `launchctl print` output. |
| `mlxctl logs <name> [-f]` | Tail stdout and stderr. |

### Metrics

| Command | Effect |
|---|---|
| `mlxctl ps` | Per-server PID, CPU%, RSS, uptime (one-shot). |
| `mlxctl top [-n SECS]` | Same as `ps`, refreshing every N seconds (default 2). Ctrl+C to exit. |

For more detail:

- Per-request tokens/sec and prompt/decode timings: `mlxctl logs <name> -f`. `mlx_lm.server` prints these at INFO.
- System GPU / ANE / power: `brew install asitop`, then `asitop`.
- GUI: Activity Monitor > View > GPU History.

### Chat UI

| Command | Effect |
|---|---|
| `mlxctl chat [--port N] [--no-open]` | Serve a static web chat at `http://127.0.0.1:7780`. Picks any configured endpoint, streams responses, shows reasoning blocks for thinking models, displays TTFT and tokens/sec. |

Static HTML and JS served via Python's `http.server`. The page talks to MLX directly, with no proxy, so it exercises the same code path as a normal client. Useful for isolating whether a problem is in a real client or in MLX.

Requires `python3` (bundled with macOS).

### Integrations

#### Omegon

[Omegon](https://github.com/styrene-lab/omegon) is a Rust agent harness. Its OpenAI client honors `OPENAI_BASE_URL`, so any mlxctl endpoint works as an Omegon backend via the `openai` provider with the full HuggingFace repo id as the model.

| Command | Effect |
|---|---|
| `mlxctl omegon` | List configured endpoints with their Omegon-ready model id (`openai:<model>`). |
| `mlxctl omegon <name>` | Print `export OPENAI_BASE_URL=...` and `OPENAI_API_KEY=dummy` on stdout, plus the TUI commands on stderr. Designed for `eval "$(mlxctl omegon <name>)"`. |
| `mlxctl omegon <name> --slash` | Print only the Omegon TUI slash commands. Paste these inside a running session. |

Typical flow:

```bash
eval "$(mlxctl omegon qwen)"   # sets OPENAI_BASE_URL (host only, no /v1),
                               # sets OPENAI_API_KEY=dummy, unsets OLLAMA_HOST
omegon                         # launches with the env in place
# inside the TUI:
#   /login openai              # paste 'dummy' as the API key
#   /model openai:mlx-community/Qwen3-Coder-Next-4bit
```

Three gotchas:

1. **`OPENAI_BASE_URL` must not include `/v1`.** Omegon's OpenAI client appends `/v1/chat/completions` itself. A `/v1` suffix produces `/v1/v1/chat/completions` (404). `mlxctl omegon` strips it.
2. **`OLLAMA_HOST` overrides provider selection.** If exported in your shell, Omegon defaults to the Ollama provider and sends Ollama-style names like `gemma4:26b`, which MLX rejects because HuggingFace repo ids cannot contain `:`. `mlxctl omegon` unsets it.
3. **Reasoning models return empty content by default.** Gemma 4, DeepSeek-R1, and Qwen3-Thinking emit chain-of-thought in `message.reasoning`. Omegon's OpenAI client only renders `content`. With `mlx_lm.server`'s default `max_tokens=512`, the model often exhausts the budget inside `reasoning` and `content` stays empty. Two workarounds:

   - **Disable thinking on the server.** Add to the model's `extraArgs`:
     ```json
     "extraArgs": ["--chat-template-args", "{\"enable_thinking\":false}"]
     ```
     Then `mlxctl restart <name>`. The chat template skips the `<think>` block and the model writes directly into `content`. Verify with:
     ```bash
     curl -sS -X POST http://127.0.0.1:8082/v1/chat/completions \
       -H 'Content-Type: application/json' \
       -d '{"model":"<id>","messages":[{"role":"user","content":"say hi"}],"max_tokens":50}'
     ```
   - **Keep thinking on and raise the budget.** Add `--max-tokens 4096` to `extraArgs`. Omegon will still show empty bubbles until its client reads `reasoning`, but `mlxctl chat` and other reasoning-aware clients will see the trace.

   Qwen3-Coder is not a reasoning model. It works without any flags.

##### Why reasoning models behave this way under MLX

Reasoning models are trained to wrap chain-of-thought in `<think>...</think>` before the final answer. Servers handle those tags differently:

| Server | `<think>` handling | Effect |
|---|---|---|
| Ollama | Merges thought and answer into a single `message.content` string, or strips `<think>` entirely depending on the model. | Any OpenAI-compatible client sees a normal response. |
| `mlx_lm.server` | Splits them. Chain-of-thought goes into `message.reasoning`; the final answer goes into `message.content`. | Clients that only read `content` see what the model wrote after `</think>`. If the budget runs out first, `content` is empty. |

So the same Gemma 4 model works under Ollama and looks broken under MLX+Omegon. The model is fine. The response shape changed.

`mlx_lm.server`'s default `--max-tokens` is 512. That is enough for a non-reasoning model and not enough for one that spends 200 to 800 tokens thinking before answering. When the budget runs out mid-thought, MLX returns `finish_reason: "length"` with `reasoning` populated and `content` empty.

Two ways out:

- `chat_template_kwargs: {"enable_thinking": false}`, either baked into server args (above) or sent per request. Gemma 4 and Qwen3 honor it via their chat template. Cheapest at inference time because no tokens are wasted on thinking.
- Increase `max_tokens` and accept the wasted thinking tokens. Useful if some clients want the reasoning visible and others do not, since the server stays uniform.

If Omegon adds support for `reasoning`, neither workaround is needed.

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

Optional per-server fields:

| Field | Default | Notes |
|---|---|---|
| `host` | `127.0.0.1` | Bind address. Use `0.0.0.0` for LAN. |
| `bin` | auto-detected | Override path to `mlx_lm.server` (e.g. a specific venv). |
| `extraArgs` | `[]` | Passed verbatim to `mlx_lm.server`. |

Edit it directly with `mlxctl edit`, then `mlxctl restart <name>` to apply.

## Paths

| Thing | Location |
|---|---|
| Config | `~/.config/mlxctl/servers.json` |
| Plists | `~/Library/LaunchAgents/dev.local.mlxctl.<name>.plist` |
| Logs | `~/Library/Logs/mlxctl/<name>.{out,err}.log` |

## How it works

`mlxctl start <name>` writes a `launchd` plist with `RunAtLoad=true` and `KeepAlive=true`, then `launchctl bootstrap`s it into `gui/$UID`. That is the whole mechanism.

Inspect what's loaded:

```bash
launchctl list | grep mlxctl
mlxctl status qwen
```

## Common patterns

### Switching ports

```bash
mlxctl edit              # change "port": 8081 to "port": 9090
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

### Stop everything

```bash
for s in $(jq -r '.servers[].name' ~/.config/mlxctl/servers.json); do
  mlxctl stop "$s"
done
```

## Notes on "OpenAI-compatible"

"OpenAI-compatible" guarantees the URL shape and JSON skeleton. It does not guarantee anything else. Every layer below the wire format varies between implementations.

### Layers that vary

| Layer | What can break |
|---|---|
| URL shape | Some clients want `OPENAI_BASE_URL=http://host:port`. Others want `.../v1`. Wrong choice produces `404 /v1/v1/chat/completions` or `404 /chat/completions`. |
| Provider selection | Env vars like `OLLAMA_HOST` or `ANTHROPIC_API_KEY` can change which adapter a multi-provider client picks. Check the client's footer or status before debugging the wire. |
| Model id grammar | Ollama tags use `:` (`gemma4:26b`). HuggingFace repo ids forbid `:` (`mlx-community/gemma-4-26b-a4b-it-4bit`). Wrong shape usually returns a terse error. |
| Auth conventions | OpenAI wants `Authorization: Bearer <key>`. Some local servers accept any non-empty string. A few reject the header entirely. |
| Default knobs | `mlx_lm.server` defaults `max_tokens=512`. Other servers default higher. A reasoning model on the low default goes silent. |
| Response shape extensions | OpenAI added `message.reasoning` for o-series. MLX adopted it for any reasoning-capable model. Ollama merges everything into `content`. Clients that predate the extension only read `content`. |
| Capability detection | Some clients keep a hardcoded allowlist of "reasoning models." If your model name is not on the list, the reasoning field is silently dropped. |
| Chat template semantics | `enable_thinking: false`, `tools`, `response_format`. Each is honored by some templates and ignored by others. The same flag can mean different things across models. |
| Streaming format | Ollama is line-delimited JSON. OpenAI is Server-Sent Events (`data: {...}\n\n` framing, `data: [DONE]` terminator). Not interchangeable. |
| Tool calling | OpenAI uses `tool_calls` arrays. Anthropic uses `tool_use` content blocks. Ollama has its own shape. llama.cpp has another. None map cleanly. |
| Stop / finish reasons | `stop`, `length`, `end_turn`, `tool_use`, `content_filter`. Overlapping vocabularies with non-identical meanings. |
| Token counting | Input, output, reasoning, cached, reused. Each provider counts and reports differently. |

### Working approach

1. Probe new endpoints with `curl | jq` before pointing a real client at one. Print the full response, not just `content`, to spot `reasoning`, `tool_calls`, refusals, and other fields a client might drop.
2. When a response looks empty, check `finish_reason` first. `length` with empty `content` means the budget went somewhere invisible. `stop` with empty `content` means you are parsing the wrong field.
3. Trust the server's logs over the client's UI. A 200 with a blank bubble is a parser issue on the client side.
4. Treat each (model, server, client) combination as its own configuration. A fix that worked for Qwen on MLX+Omegon does not necessarily carry over to Gemma on the same stack.

### Worked example

The Gemma case above is one full instance of these layers colliding: Gemma 4 (thinks before answering) + MLX (splits thinking into a separate field) + Omegon (only reads `content`, does not recognize Gemma as a reasoning model) + `max_tokens=512` default (thinking exhausts the budget). Pulling any one of the four threads fixes it. We chose the chat template (`enable_thinking:false`). Raising `max_tokens`, switching client, or switching server would also work.

## License

MIT
