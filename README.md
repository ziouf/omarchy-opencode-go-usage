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

Keys resolve from the environment first, then from OpenCode's own auth store
(`~/.local/share/opencode/auth.json`, written by `/connect` in the TUI):

| Provider | Environment variable | auth.json entry |
| --- | --- | --- |
| OpenCode Go | `OPENCODE_GO_API_KEY` | `opencode-go` |
| OpenRouter | `OPENROUTER_API_KEY` | `openrouter` |
| OpenAI Platform | `OPENAI_API_KEY` | `openai` |

Claude Code, Codex, Fireworks and DeepSeek Harness keep using the stock
Omarchy collectors untouched.

To centralize API keys for several tools, export them from a session env file
such as `~/.config/uwsm/env.d/api-keys.sh` (requires a session restart). Mind
that session environment variables are readable by every process in your
session; the `auth.json` fallback keeps keys scoped instead.

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
