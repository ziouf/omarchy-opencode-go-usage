#!/usr/bin/env bash
# Fixture-based tests for the credential resolution chain of
# scripts/update-llm-quotas. Run from anywhere:
#
#   bash tests/run.sh

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../scripts/update-llm-quotas"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

pass=0
fail=0

check() {
  local desc=$1 fixture=$2 provider=$3 want=${4-} # empty want = expect failure
  local got rc
  got=$(env -u OPENCODE_GO_API_KEY -u OPENCODE_ZEN_GO_API_KEY -u ZEN_GO_API_KEY \
    -u OPENROUTER_API_KEY -u OPENAI_API_KEY \
    HOME="$fixture" bash "$SCRIPT" --resolve "$provider" 2>/dev/null)
  rc=$?
  if [[ -z $want ]]; then
    if ((rc != 0)); then
      pass=$((pass + 1))
    else
      echo "FAIL: $desc (expected miss, got a key)" >&2
      fail=$((fail + 1))
    fi
  elif ((rc == 0)) && [[ $got == "$want" ]]; then
    pass=$((pass + 1))
  else
    echo "FAIL: $desc (want '$want', got '$got', rc=$rc)" >&2
    fail=$((fail + 1))
  fi
}

mk() { mkdir -p "$ROOT/$1"; }

# ---- fixture: opencode as default agent ------------------------------------
mk fx-opencode/.config/omarchy/defaults
echo opencode >"$ROOT/fx-opencode/.config/omarchy/defaults/agent"
mkdir -p "$ROOT/fx-opencode/.local/share/opencode"
cat >"$ROOT/fx-opencode/.local/share/opencode/auth.json" <<EOF
{ "opencode-go": {"type":"api","key":"go-from-opencode"},
  "openrouter":   {"type":"api","key":"or-from-opencode"} }
EOF
check "opencode adapter -> opencode-go" "$ROOT/fx-opencode" opencode-go go-from-opencode
check "opencode adapter -> openrouter" "$ROOT/fx-opencode" openrouter or-from-opencode
check "opencode adapter -> openai miss" "$ROOT/fx-opencode" openai ""

# ---- fixture: claude as default agent --------------------------------------
mk fx-claude/.config/omarchy/defaults
echo claude >"$ROOT/fx-claude/.config/omarchy/defaults/agent"
mkdir -p "$ROOT/fx-claude/.claude"
cat >"$ROOT/fx-claude/.claude/settings.json" <<EOF
{ "env": {
    "ANTHROPIC_BASE_URL": "https://opencode.ai/zen/go",
    "ANTHROPIC_AUTH_TOKEN": "go-from-claude",
    "OPENROUTER_API_KEY": "or-from-claude" } }
EOF
check "claude adapter -> opencode-go via zen base url" "$ROOT/fx-claude" opencode-go go-from-claude
check "claude adapter -> openrouter passthrough" "$ROOT/fx-claude" openrouter or-from-claude
check "claude adapter -> openai miss" "$ROOT/fx-claude" openai ""

# Claude pointed elsewhere must not yield an opencode-go key.
mk fx-claude-other/.config/omarchy/defaults
echo claude >"$ROOT/fx-claude-other/.config/omarchy/defaults/agent"
mkdir -p "$ROOT/fx-claude-other/.claude"
cat >"$ROOT/fx-claude-other/.claude/settings.json" <<EOF
{ "env": {
    "ANTHROPIC_BASE_URL": "https://api.anthropic.com",
    "ANTHROPIC_AUTH_TOKEN": "not-ours" } }
EOF
check "claude adapter ignores non-zen base url" "$ROOT/fx-claude-other" opencode-go ""

# ---- fixture: codex as default agent ---------------------------------------
mk fx-codex/.config/omarchy/defaults
echo codex >"$ROOT/fx-codex/.config/omarchy/defaults/agent"
mkdir -p "$ROOT/fx-codex/.codex"
cat >"$ROOT/fx-codex/.codex/auth.json" <<EOF
{ "OPENAI_API_KEY": "oai-from-auth" }
EOF
cat >"$ROOT/fx-codex/.codex/config.toml" <<'EOF'
[model_providers.openrouter]
base_url = "https://openrouter.ai/api/v1"

[model_providers.opencode]
name = "OpenCode Go"
base_url = "https://opencode.ai/zen/go/v1"
api_key = "go-from-toml"
EOF
check "codex adapter -> openai auth.json" "$ROOT/fx-codex" openai oai-from-auth
check "codex adapter -> opencode-go config.toml" "$ROOT/fx-codex" opencode-go go-from-toml
check "codex adapter -> openrouter miss (no literal)" "$ROOT/fx-codex" openrouter ""

# Codex without an OPENAI_API_KEY in auth.json must not break the walk.
mk fx-codex-min/.config/omarchy/defaults
echo codex >"$ROOT/fx-codex-min/.config/omarchy/defaults/agent"
mkdir -p "$ROOT/fx-codex-min/.codex"
cat >"$ROOT/fx-codex-min/.codex/config.toml" <<'EOF'
[model_providers.opencode]
base_url = "https://opencode.ai/zen/go/v1"
api_key = "go-from-toml"
EOF
check "codex adapter survives missing auth.json" "$ROOT/fx-codex-min" opencode-go go-from-toml
check "codex adapter survives missing auth.json (2)" "$ROOT/fx-codex-min" openai ""

# A partially populated opencode store must not break the walk either.
mk fx-opencode-partial/.config/omarchy/defaults
echo opencode >"$ROOT/fx-opencode-partial/.config/omarchy/defaults/agent"
mkdir -p "$ROOT/fx-opencode-partial/.local/share/opencode"
echo '{ "openai": {"type":"api","key":"oai-only"} }' \
  >"$ROOT/fx-opencode-partial/.local/share/opencode/auth.json"
check "opencode adapter partial store" "$ROOT/fx-opencode-partial" openai oai-only
check "opencode adapter partial store (2)" "$ROOT/fx-opencode-partial" opencode-go ""

# ---- fixture: dsh as default agent -----------------------------------------
mk fx-dsh/.config/omarchy/defaults
echo dsh >"$ROOT/fx-dsh/.config/omarchy/defaults/agent"
mkdir -p "$ROOT/fx-dsh/.dsh"
printf 'DEEPSEEK_API_KEY=sk-x\nOPENCODE_GO_API_KEY=go-from-dsh\n' \
  >"$ROOT/fx-dsh/.dsh/.env"
check "dsh adapter -> opencode-go .env" "$ROOT/fx-dsh" opencode-go go-from-dsh
check "dsh adapter -> openai miss" "$ROOT/fx-dsh" openai ""

# ---- env wins over the adapter ---------------------------------------------
mk fx-env-win/.config/omarchy/defaults
echo opencode >"$ROOT/fx-env-win/.config/omarchy/defaults/agent"
mkdir -p "$ROOT/fx-env-win/.local/share/opencode"
echo '{ "opencode-go": {"type":"api","key":"from-store"} }' \
  >"$ROOT/fx-env-win/.local/share/opencode/auth.json"
got=$(HOME="$ROOT/fx-env-win" OPENCODE_GO_API_KEY=from-session \
  bash "$SCRIPT" --resolve opencode-go 2>/dev/null)
if [[ $got == from-session ]]; then
  pass=$((pass + 1))
else
  echo "FAIL: session env must outrank agent stores (got '$got')" >&2
  fail=$((fail + 1))
fi

# ---- manual override file as last resort ------------------------------------
mk fx-file/.config/omarchy
rm -f "$ROOT/fx-file/.config/omarchy/defaults/agent"
printf '# comment\nOPENROUTER_API_KEY=or-from-file\n' >"$ROOT/fx-file/.config/omarchy/api-keys.env"
check "api-keys.env fallback" "$ROOT/fx-file" openrouter or-from-file
check "api-keys.env scoped to listed names" "$ROOT/fx-file" opencode-go ""

# ---- unknown agent, nothing anywhere ----------------------------------------
mk fx-none/.config/omarchy/defaults
echo gemini >"$ROOT/fx-none/.config/omarchy/defaults/agent"
check "unknown agent stays silent" "$ROOT/fx-none" opencode-go ""
check "unknown agent stays silent (2)" "$ROOT/fx-none" openai ""

echo "passed=$pass failed=$fail"
((fail == 0))
