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
  local desc=$1 fixture=$2 want=${3-} prov=${4:-opencode-go} # empty want = expect failure
  local got rc
  got=$(env -u OPENCODE_GO_API_KEY -u OPENCODE_ZEN_GO_API_KEY -u ZEN_GO_API_KEY -u OPENROUTER_API_KEY \
    HOME="$fixture" bash "$SCRIPT" --resolve "$prov" 2>/dev/null)
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

# ---- fixture: openrouter key alongside opencode -----------------------------
mk fx-or/.config/omarchy/defaults
echo opencode >"$ROOT/fx-or/.config/omarchy/defaults/agent"
mkdir -p "$ROOT/fx-or/.local/share/opencode"
cat >"$ROOT/fx-or/.local/share/opencode/auth.json" <<EOF
{ "opencode-go": {"type":"api","key":"go-here"},
  "openrouter": {"type":"api","key":"or-from-store"} }
EOF
check "opencode adapter also yields openrouter entry" "$ROOT/fx-or" or-from-store openrouter
check "go entry unaffected by openrouter" "$ROOT/fx-or" go-here opencode-go

# Session env wins for openrouter too (strip ambient first for hermeticity).
got=$(HOME="$ROOT/fx-or" \
  env -u OPENROUTER_API_KEY OPENROUTER_API_KEY=or-from-session \
  bash "$SCRIPT" --resolve openrouter 2>/dev/null)
if [[ $got == or-from-session ]]; then
  pass=$((pass + 1))
else
  echo "FAIL: session env must outrank store for openrouter (got '$got')" >&2
  fail=$((fail + 1))
fi

# Manual override file covers openrouter as well.
mk fx-or-file/.config/omarchy
printf '# comment\nOPENROUTER_API_KEY=or-from-file\n' \
  >"$ROOT/fx-or-file/.config/omarchy/api-keys.env"
check "api-keys.env fallback for openrouter" "$ROOT/fx-or-file" or-from-file openrouter

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

# ---- openrouter record mapping (fixtures, no network) -----------------------
# Source just the record builders (no fetch, no writes) and assert the
# rendered record per locale and per key shape.
ormap() {
  local loc=$1 fixture=$2 want=$3 desc=$4 got
  got=$(LOC_T="$loc" FIXTURE="$fixture" SCRIPT="$SCRIPT" bash -c '
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    source <(sed -n "/^record_envelope() {/,/^}/p;/^merge_fields() {/,/^}/p;/^build_openrouter_record() {/,/^}/p;/^next_month_start() {/,/^}/p;/^t() {/,/^}/p;/^declare -A _STR/,/^_STR\[en.or_nocap\]/p" "$SCRIPT")
    build_openrouter_record "$FIXTURE" "$LOC_T" | jq -c "{tier: .tierLabel, rem: .balance.remaining, funded: .balance.funded, spent: .balance.spent, cur: .balance.currency, title: .limits[0].title, pct: .limits[0].percent, reset_ok: ((.limits[0].resetsAt // \"\") | test(\"^[0-9]{4}-[0-9]{2}-01T\")), info: .infoLines, status_ok: (.usageStatusText | test(\"exhausted|épuisé\"))}"
  ')
  if [[ $got == "$want" ]]; then
    pass=$((pass + 1))
  else
    echo "FAIL: $desc got '$got' want '$want'" >&2
    fail=$((fail + 1))
  fi
}

OR_FULL='{"data":{"label":"k","limit":100,"limit_remaining":74.5,"limit_reset":"monthly","usage":25.5,"usage_daily":1,"usage_weekly":5,"usage_monthly":25.5,"is_free_tier":false}}'
OR_NOCAP='{"data":{"label":"k","limit":0,"limit_remaining":0,"limit_reset":null,"usage":10,"usage_daily":0,"usage_weekly":0,"usage_monthly":10}}'
OR_NULL='{"data":{"label":"k","limit":null,"limit_remaining":null,"limit_reset":null,"usage":10,"usage_monthly":10}}'
OR_EMPTY='{"data":{"label":"k","limit":100,"limit_remaining":0,"limit_reset":"monthly","usage":100,"usage_monthly":100}}'

ormap en "$OR_FULL" '{"tier":"Pay as you go","rem":74.5,"funded":100,"spent":25.5,"cur":"USD","title":"Monthly","pct":0.255,"reset_ok":true,"info":[],"status_ok":false}' "openrouter en with cap"
ormap fr "$OR_FULL" '{"tier":"Paiement à l'"'"'usage","rem":74.5,"funded":100,"spent":25.5,"cur":"USD","title":"Mensuel","pct":0.255,"reset_ok":true,"info":[],"status_ok":false}' "openrouter fr with cap"
ormap en "$OR_NOCAP" '{"tier":"Pay as you go","rem":null,"funded":null,"spent":null,"cur":null,"title":null,"pct":null,"reset_ok":false,"info":["$10 spent this month, no cap on this key"],"status_ok":false}' "openrouter en cap 0 -> info line"
ormap en "$OR_NULL" '{"tier":"Pay as you go","rem":null,"funded":null,"spent":null,"cur":null,"title":null,"pct":null,"reset_ok":false,"info":["$10 spent this month, no cap on this key"],"status_ok":false}' "openrouter en cap null -> info line"
ormap fr "$OR_NOCAP" '{"tier":"Paiement à l'"'"'usage","rem":null,"funded":null,"spent":null,"cur":null,"title":null,"pct":null,"reset_ok":false,"info":["$10 dépensés ce mois-ci, sans plafond sur cette clé"],"status_ok":false}' "openrouter fr cap 0 -> info line"
ormap en "$OR_EMPTY" '{"tier":"Pay as you go","rem":0,"funded":100,"spent":100,"cur":"USD","title":"Monthly","pct":1,"reset_ok":true,"info":[],"status_ok":true}' "openrouter en exhausted status"

echo "passed=$pass failed=$fail"
((fail == 0))
