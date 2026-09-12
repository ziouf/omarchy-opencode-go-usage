# LLM quotas for Omarchy

A **service plugin** that enriches the built-in [Omarchy](https://omarchy.org)
**Agents** panel with LLM quota tabs: **OpenCode Go** and **OpenRouter**. It ships no widget and no
UI of its own: it only writes the usage record where the stock panel already
looks, so your existing Agents tab grows the provider automatically — nothing
is replaced, patched, or duplicated.

The tabs show live quotas, one tab per provider with a resolvable credential:

| Tab | Endpoint | What you see |
| --- | --- | --- |
| OpenCode Go | `GET https://opencode.ai/zen/go/v1/usage` | rolling 5-hour, weekly, and monthly usage with meters, reset countdowns, and a red state past 90 % |
| OpenRouter | `GET https://openrouter.ai/api/v1/key` | credit balance (remaining / funded / spent, USD) plus a monthly-spend meter when the key carries a cap; cap-less keys show the monthly spend as text instead of a percentage |

Without resolvable credentials the tab never appears; a failed fetch keeps the
previous record visible until the next attempt succeeds.

## Language

The tab's labels follow your system's locale (read from `$LANG`/`$LC_ALL`, or
the `locale` command when those are unset). French and English are bundled; any
other locale falls back to English. Only the tab's labels are localized — the
credential resolution below never depends on the language.

## Requirements

- Omarchy (Hyprland + omarchy-shell)
- An OpenCode Go subscription with a credential reachable on this machine

## Installation

```bash
omarchy plugin add https://github.com/ziouf/omarchy-opencode-go-quotas.git --enable
```

Then make sure the service is enabled in `~/.config/omarchy/shell.json`
(`omarchy plugin add --enable` normally does it):

```json
{ "plugins": [ { "id": "ziouf.llm-quotas" } ] }
```

Open your Agents bar widget: the OpenCode Go and OpenRouter tabs are there. The service
refreshes every minute; you can force it with:

```bash
omarchy-shell ziouf.llm-quotas refresh
```

## Credential resolution

The key is resolved on every refresh — first hit wins:

1. **Session environment variables**: `OPENCODE_GO_API_KEY` (aliases:
   `OPENCODE_ZEN_GO_API_KEY`, `ZEN_GO_API_KEY`) for OpenCode Go,
   `OPENROUTER_API_KEY` for OpenRouter.
2. **The system's default AI agent** (`omarchy default agent`): a dedicated
   adapter reads that agent's own configuration files, so the plugin never
   depends on one harness being installed.

   | Agent | Files read (read-only) |
   | --- | --- |
   | `opencode` | `~/.local/share/opencode/auth.json`, `opencode-go` and `openrouter` entries |
   | `claude` | `~/.claude/settings.json` `env` block — an `ANTHROPIC_AUTH_TOKEN` only counts when `ANTHROPIC_BASE_URL` points at `opencode.ai/zen` |
   | `codex` | literal `api_key` from `[model_providers.*]` tables in `~/.codex/config.toml` aimed at `opencode.ai` |
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
are private to each tool; adapters are covered by `tests/run.sh`.

## How it works

Omarchy's Agents panel displays one JSON record per agent from
`~/.local/state/omarchy/agents/usage/`, and picks up any record that appears.
Packaged collectors cover Claude/Codex/Fireworks; this plugin adds its own
OpenCode Go collector, run on a timer inside omarchy-shell (the API response
is cached a few minutes, so polling stays polite).

## Troubleshooting

- **The tab never appears** — no credential resolved. Check what the resolver
  finds, in the same order the service uses:

  ```bash
  bash ~/.config/omarchy/plugins/ziouf.llm-quotas/scripts/update-opencode-go \
    --resolve
  ```

  Exit code 1 with "no credential resolved" means every tier missed.
- **Numbers look stale** — a fetch failed and the previous record is kept on
  purpose; shell errors surface in `journalctl --user | grep -i
  opencode-go`. Force a fresh pull with `omarchy-shell
  ziouf.llm-quotas refresh`.

## Uninstall

```bash
omarchy plugin remove ziouf.llm-quotas
```

The tab disappears from the Agents panel on the next rescan. Optional spotless
cleanup:

```bash
rm -f ~/.local/state/omarchy/agents/usage/opencode-go.json
rm -f ~/.cache/omarchy/opencode-go-usage.json
rm -f ~/.local/state/omarchy/agents/usage/openrouter.json
rm -f ~/.cache/omarchy/openrouter-key.json
rm -f ~/.config/omarchy/api-keys.env   # only if nothing else uses it
```

## License

[MIT](LICENSE)
