# OpenCode Go quotas for Omarchy

A **service plugin** that enriches the built-in [Omarchy](https://omarchy.org)
**Agents** panel with LLM quota tabs. It ships no widget and no UI of its own:
it only writes usage records where the stock panel already looks, so your
existing Agents tab grows the new providers automatically — nothing is
replaced, patched, or duplicated.

| Provider | Tab shows | Source |
| --- | --- | --- |
| **OpenCode Go** | Rolling 5-hour / weekly / monthly windows, meters, reset countdowns | Official `GET opencode.ai/zen/go/v1/usage` |
| **OpenRouter** | Balance and spending cap (live spend on free tier) | Official `api/v1/key` + `api/v1/credits` |
| **OpenAI Platform** | Monthly usage vs. hard limit | Dashboard billing endpoints |

Providers without stored credentials never appear; a failed fetch keeps the
previous record visible until the next attempt succeeds.

## Requirements

- Omarchy (Hyprland + omarchy-shell)
- Credentials for the providers you want to track

## Installation

```bash
omarchy plugin add https://github.com/ziouf/omarchy-opencode-go-quotas.git --enable
```

Then make sure the service is enabled in `~/.config/omarchy/shell.json`
(`omarchy plugin add --enable` normally does it):

```json
{ "plugins": [ { "id": "ziouf.opencode-go-quotas" } ] }
```

Open your Agents bar widget: new tabs are there. The service refreshes every
5 minutes; you can force it with:

```bash
omarchy-shell ziouf.opencode-go-quotas refresh
```

## Provider credentials

Keys are resolved per provider — first hit wins:

1. **Session environment variables**: `OPENCODE_GO_API_KEY` (aliases:
   `OPENCODE_ZEN_GO_API_KEY`, `ZEN_GO_API_KEY`), `OPENROUTER_API_KEY`,
   `OPENAI_API_KEY`.
2. **The system's default AI agent** (`omarchy default agent`): a dedicated
   adapter reads that agent's own configuration files, so the plugin never
   depends on one harness being installed.

   | Agent | Files read (read-only) |
   | --- | --- |
   | `opencode` | `~/.local/share/opencode/auth.json` |
   | `claude` | `~/.claude/settings.json` `env` block — an `ANTHROPIC_AUTH_TOKEN` only counts when `ANTHROPIC_BASE_URL` points at `opencode.ai/zen` |
   | `codex` | `~/.codex/auth.json`; literal `api_key` from `config.toml` `[model_providers.*]` tables aimed at `opencode.ai` |
   | `dsh` | `~/.dsh/.env` |

   Other agents (`pi`, `omp`, `grok`, `gemini`, `copilot`, `crush`) have no
   adapter yet and simply contribute nothing.
3. **Manual override file** `~/.config/omarchy/api-keys.env` — plain
   `KEY=value` lines, parsed literally and never sourced:

   ```bash
   install -m 600 /dev/null ~/.config/omarchy/api-keys.env
   printf 'OPENCODE_GO_API_KEY=%s\n' "sk-..." >> ~/.config/omarchy/api-keys.env
   ```

Agent configuration files are only ever read, never written. Their formats
are private to each tool; adapters are covered by `tests/run.sh`. Claude
Code, Codex, Fireworks and DeepSeek Harness usage stats keep using the stock
Omarchy collectors untouched.

## How it works

Omarchy's Agents panel displays one JSON record per agent from
`~/.local/state/omarchy/agents/usage/`, and picks up any record that appears.
Packaged collectors cover Claude/Codex/Fireworks; this plugin adds its own
collectors for extra providers, run on a timer inside omarchy-shell (the API
responses are cached a few minutes each, so polling stays polite).

## Uninstall

```bash
omarchy plugin remove ziouf.opencode-go-quotas
```

The tabs disappear from the Agents panel on the next rescan. Optional spotless
cleanup of records and caches:

```bash
rm -f ~/.local/state/omarchy/agents/usage/{opencode-go,openrouter,openai}.json
rm -f ~/.cache/omarchy/{opencode-go-usage,openrouter-key,openrouter-credits,openai-subscription,openai-usage}.json
```

## License

[MIT](LICENSE)
