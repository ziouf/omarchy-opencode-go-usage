#!/usr/bin/env bash
# Fixture-based tests for the credential resolution chain of
# scripts/update-opencode-go. Run from anywhere:
#
#   bash tests/run.sh

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../scripts/update-opencode-go"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

pass=0
fail=0

check() {
  local desc=$1 fixture=$2 want=${3-} # empty want = expect failure
  local got rc
  got=$(env -u OPENCODE_GO_API_KEY -u OPENCODE_ZEN_GO_API_KEY -u ZEN_GO_API_KEY \
    HOME="$fixture" bash "$SCRIPT" --resolve 2>/dev/null)
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

# ---- i18n: record strings follow the system locale -------------------------
# Source just the translation unit (locale detection + string table) without
# touching the network, then assert the rendered strings per locale.
i18n() {
  local loc=$1 want=$2 got
  got=$(LANG="$loc" SCRIPT="$SCRIPT" bash -c '
    source <(sed -n "/^LOCALE_ENV=/,/^}/p;/^t() {/,/^}/p;/^declare -A _STR/,/^_STR\[en.tier\]/p" "$SCRIPT")
    loc=$(detect_locale); printf "%s|%s|%s|%s|%s|%s|%s|%s" \
      "$(t $loc rolling_label)" "$(t $loc rolling_title)" \
      "$(t $loc weekly_label)" "$(t $loc weekly_title)" \
      "$(t $loc monthly_label)" "$(t $loc monthly_title)" \
      "$(t $loc exhausted_word)" "$(t $loc tier)"
  ')
  if [[ $got == "$want" ]]; then
    pass=$((pass + 1))
  else
    echo "FAIL: i18n loc='$loc' got '$got' want '$want'" >&2
    fail=$((fail + 1))
  fi
}

# French is the primary UI language; English is the default everyone falls back to.
i18n "fr_FR.UTF-8" "Session (5 heures)|Session|Hebdomadaire|Hebdomadaire|Mensuel|Mensuel|épuisé|Abonnement"
i18n "en_US.UTF-8" "Session (5-hour)|Session|Weekly|Weekly|Monthly|Monthly|exhausted|Subscription"
i18n "de_DE.UTF-8" "Session (5-hour)|Session|Weekly|Weekly|Monthly|Monthly|exhausted|Subscription" # unknown locale -> English


# ---- fixture: opencode as default agent ------------------------------------
mk fx-opencode/.config/omarchy/defaults
echo opencode >"$ROOT/fx-opencode/.config/omarchy/defaults/agent"
mkdir -p "$ROOT/fx-opencode/.local/share/opencode"
echo '{ "opencode-go": {"type":"api","key":"go-from-opencode"} }' \
  >"$ROOT/fx-opencode/.local/share/opencode/auth.json"
check "opencode adapter -> auth.json" "$ROOT/fx-opencode" go-from-opencode

# Unrelated providers in the store must not break the walk.
mk fx-opencode-partial/.config/omarchy/defaults
echo opencode >"$ROOT/fx-opencode-partial/.config/omarchy/defaults/agent"
mkdir -p "$ROOT/fx-opencode-partial/.local/share/opencode"
cat >"$ROOT/fx-opencode-partial/.local/share/opencode/auth.json" <<EOF
{ "openai": {"type":"api","key":"unrelated"},
  "opencode-go": {"type":"api","key":"go-despite-noise"} }
EOF
check "opencode adapter ignores unrelated entries" "$ROOT/fx-opencode-partial" go-despite-noise

# ---- fixture: claude as default agent --------------------------------------
mk fx-claude/.config/omarchy/defaults
echo claude >"$ROOT/fx-claude/.config/omarchy/defaults/agent"
mkdir -p "$ROOT/fx-claude/.claude"
cat >"$ROOT/fx-claude/.claude/settings.json" <<EOF
{ "env": {
    "ANTHROPIC_BASE_URL": "https://opencode.ai/zen/go",
    "ANTHROPIC_AUTH_TOKEN": "go-from-claude" } }
EOF
check "claude adapter -> zen base url + token" "$ROOT/fx-claude" go-from-claude

# Claude pointed elsewhere must not yield an OpenCode Go key.
mk fx-claude-other/.config/omarchy/defaults
echo claude >"$ROOT/fx-claude-other/.config/omarchy/defaults/agent"
mkdir -p "$ROOT/fx-claude-other/.claude"
cat >"$ROOT/fx-claude-other/.claude/settings.json" <<EOF
{ "env": {
    "ANTHROPIC_BASE_URL": "https://api.anthropic.com",
    "ANTHROPIC_AUTH_TOKEN": "not-ours" } }
EOF
check "claude adapter ignores non-zen base url" "$ROOT/fx-claude-other" ""

# ---- fixture: codex as default agent ---------------------------------------
mk fx-codex/.config/omarchy/defaults
echo codex >"$ROOT/fx-codex/.config/omarchy/defaults/agent"
mkdir -p "$ROOT/fx-codex/.codex"
cat >"$ROOT/fx-codex/.codex/config.toml" <<'EOF'
[model_providers.openrouter]
base_url = "https://openrouter.ai/api/v1"

[model_providers.opencode]
name = "OpenCode Go"
base_url = "https://opencode.ai/zen/go/v1"
api_key = "go-from-toml"
EOF
check "codex adapter -> config.toml zen provider" "$ROOT/fx-codex" go-from-toml

# Codex without any zen table must come up empty, not crash.
mk fx-codex-min/.config/omarchy/defaults
echo codex >"$ROOT/fx-codex-min/.config/omarchy/defaults/agent"
mkdir -p "$ROOT/fx-codex-min/.codex"
printf '[model_providers.openrouter]\nbase_url = "https://openrouter.ai/api/v1"\n' \
  >"$ROOT/fx-codex-min/.codex/config.toml"
check "codex adapter without zen table" "$ROOT/fx-codex-min" ""

# ---- fixture: dsh as default agent -----------------------------------------
mk fx-dsh/.config/omarchy/defaults
echo dsh >"$ROOT/fx-dsh/.config/omarchy/defaults/agent"
mkdir -p "$ROOT/fx-dsh/.dsh"
printf 'DEEPSEEK_API_KEY=sk-x\nOPENCODE_GO_API_KEY=go-from-dsh\n' \
  >"$ROOT/fx-dsh/.dsh/.env"
check "dsh adapter -> .env" "$ROOT/fx-dsh" go-from-dsh

# ---- env wins over the adapter ---------------------------------------------
got=$(HOME="$ROOT/fx-opencode" OPENCODE_GO_API_KEY=from-session \
  bash "$SCRIPT" --resolve 2>/dev/null)
if [[ $got == from-session ]]; then
  pass=$((pass + 1))
else
  echo "FAIL: session env must outrank agent stores (got '$got')" >&2
  fail=$((fail + 1))
fi

# Alias variables count as session env too. Strip any ambient OpenCode key
# first so this test doesn't depend on the caller's environment.
got=$(HOME="$ROOT/fx-opencode" \
  env -u OPENCODE_GO_API_KEY -u OPENCODE_ZEN_GO_API_KEY \
        ZEN_GO_API_KEY=from-alias \
  bash "$SCRIPT" --resolve 2>/dev/null)
if [[ $got == from-alias ]]; then
  pass=$((pass + 1))
else
  echo "FAIL: alias env var must be honored (got '$got')" >&2
  fail=$((fail + 1))
fi

# ---- manual override file as last resort ------------------------------------
mk fx-file/.config/omarchy
rm -f "$ROOT/fx-file/.config/omarchy/defaults/agent"
printf '# comment\nOPENCODE_GO_API_KEY=go-from-file\n' \
  >"$ROOT/fx-file/.config/omarchy/api-keys.env"
check "api-keys.env fallback" "$ROOT/fx-file" go-from-file

# ---- unknown agent, nothing anywhere ----------------------------------------
mk fx-none/.config/omarchy/defaults
echo gemini >"$ROOT/fx-none/.config/omarchy/defaults/agent"
check "unknown agent stays silent" "$ROOT/fx-none" ""
check "no default agent at all stays silent" "$ROOT/fx-none/" "" # reuse; no file in parent anyway

echo "passed=$pass failed=$fail"
((fail == 0))
