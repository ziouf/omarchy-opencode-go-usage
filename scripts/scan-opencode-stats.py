#!/usr/bin/env python3
"""Scan the opencode database for one provider's local token usage.

Reads ~/.local/share/opencode/opencode.db (read-only) and aggregates every
assistant message that ran on a given provider (providerID in opencode's
message rows) into the local-stats shape the Agents panel renders natively
(tokens by day, tokens by model, prompts and session counts).

The scan mirrors the approach of omarchy's packaged codex collector: rows
are gated in SQL (LIKE guards + json_extract) so huge JSON blobs are never
parsed on the Python side, and a partial scan still contributes what it
read. A fresh scan cache (mirroring the API response cache) keeps the
60-second service timer from walking the database on every tick.

Usage: scan-opencode-stats.py <provider> [--force]
Prints one JSON line; exits 0 on success (an absent database is a
successful scan of nothing), 1 only when the database cannot be opened.
"""

import argparse
import json
import os
import sqlite3
import sys
import tempfile
import time
from datetime import datetime, timedelta
from pathlib import Path

CACHE_MAX_AGE_SECONDS = 240


def local_day(value):
  if value is None:
    return datetime.now().strftime("%Y-%m-%d")
  if isinstance(value, (int, float)):
    # opencode timestamps are milliseconds; tolerate seconds too.
    if value > 10_000_000_000:
      value = value / 1000
    return datetime.fromtimestamp(value).strftime("%Y-%m-%d")
  text = str(value)
  try:
    if text.endswith("Z"):
      dt = datetime.fromisoformat(text[:-1] + "+00:00")
    else:
      dt = datetime.fromisoformat(text)
    if dt.tzinfo is not None:
      dt = dt.astimezone()
    return dt.strftime("%Y-%m-%d")
  except Exception:
    return datetime.now().strftime("%Y-%m-%d")


def number(value):
  try:
    return int(value or 0)
  except Exception:
    return 0


def model_name(raw):
  value = str(raw or "unknown")
  return value.rstrip("/").split("/")[-1] if value else "unknown"


def database_path():
  return Path(os.environ.get("XDG_DATA_HOME") or (Path.home() / ".local" / "share")) / "opencode" / "opencode.db"


def cache_path(provider):
  root = Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache")) / "omarchy"
  root.mkdir(parents=True, exist_ok=True)
  return root / f"{provider}-stats.json"


def read_fresh_cache(path, today):
  if not path.exists():
    return None
  try:
    age = time.time() - path.stat().st_mtime
    if 0 <= age <= CACHE_MAX_AGE_SECONDS:
      cached = json.loads(path.read_text(encoding="utf-8"))
      if isinstance(cached, dict) and cached.get("schemaVersion") == 1 and cached.get("scanDate") == today:
        stats = cached.get("stats")
        if isinstance(stats, dict) and all(key in stats for key in ("todayPrompts", "recentDays", "modelUsage")):
          return stats
  except Exception:
    return None
  return None


def write_cache(path, today, stats):
  try:
    fd, tmp_name = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".", suffix=".tmp")
    tmp = Path(tmp_name)
    try:
      with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(json.dumps({"schemaVersion": 1, "scanDate": today, "stats": stats}, separators=(",", ":")) + "\n")
      tmp.replace(path)
    except BaseException:
      tmp.unlink(missing_ok=True)
      raise
  except Exception:
    return


def build_stats(acc, today, recent_dates):
  return {
    "todayPrompts": acc["todayPrompts"],
    "todaySessions": len(acc["todaySessions"]),
    "todayTotalTokens": acc["todayTotalTokens"],
    "todayTokensByModel": acc["todayTokensByModel"],
    "recentDays": [{"date": day, "messageCount": acc["recent"][day]} for day in recent_dates],
    "totalPrompts": acc["totalPrompts"],
    "totalSessions": len(acc["totalSessions"]),
    "activeDays": len(acc["activeDates"]),
    "activeDates": sorted(acc["activeDates"]),
    "modelUsage": acc["modelUsage"],
  }


def scan(provider):
  now = datetime.now()
  today = now.strftime("%Y-%m-%d")
  recent_dates = [(now - timedelta(days=offset)).strftime("%Y-%m-%d") for offset in range(6, -1, -1)]
  acc = {
    "todayPrompts": 0,
    "todaySessions": set(),
    "todayTotalTokens": 0,
    "todayTokensByModel": {},
    "totalPrompts": 0,
    "totalSessions": set(),
    "activeDates": set(),
    "recent": {day: 0 for day in recent_dates},
    "modelUsage": {},
  }

  db = database_path()
  if not db.is_file():
    return build_stats(acc, today, recent_dates)

  quoted = provider.replace("'", "''")
  try:
    conn = sqlite3.connect(db.resolve().as_uri() + "?mode=ro", uri=True, timeout=2)
  except sqlite3.Error:
    return None
  try:
    conn.execute("PRAGMA query_only = ON")
    # The LIKE gates skip rows whose JSON cannot contain the key/value pairs
    # (avoiding a JSON parse of tens-of-MB blobs); json_valid guards the
    # json_extract calls, which raise on malformed JSON. The json_extract
    # conditions remain the authority, checked again in Python per row.
    for session_id, raw in conn.execute(
      "SELECT session_id, data FROM message"
      " WHERE data LIKE '%\"role\"%:%\"assistant\"%'"
      " AND data LIKE '%\"providerID\"%:%\"" + quoted + "\"%'"
      " AND CASE WHEN json_valid(data) THEN json_extract(data, '$.role') END = 'assistant'"
      " AND CASE WHEN json_valid(data) THEN json_extract(data, '$.providerID') END = ?",
      (provider,),
    ):
      try:
        entry = json.loads(raw)
        if not isinstance(entry, dict) or entry.get("role") != "assistant":
          continue
        if str(entry.get("providerID") or "") != provider:
          continue
        tokens = entry.get("tokens") or {}
        cache = tokens.get("cache") or {}
        input_tokens = number(tokens.get("input"))
        # opencode keeps thinking tokens out of output; both are generated.
        output_tokens = number(tokens.get("output")) + number(tokens.get("reasoning"))
        cache_read = number(cache.get("read"))
        cache_write = number(cache.get("write"))
        if not (input_tokens or output_tokens or cache_read or cache_write):
          continue
        day = local_day((entry.get("time") or {}).get("created"))
        model = model_name(entry.get("modelID"))
      except Exception:
        continue

      total = input_tokens + output_tokens + cache_read + cache_write
      session_key = "opencode:" + str(session_id)
      acc["totalPrompts"] += 1
      acc["totalSessions"].add(session_key)
      acc["activeDates"].add(day)

      bucket = acc["modelUsage"].setdefault(model, {
        "inputTokens": 0,
        "outputTokens": 0,
        "cacheReadInputTokens": 0,
        "cacheCreationInputTokens": 0,
      })
      bucket["inputTokens"] += input_tokens
      bucket["outputTokens"] += output_tokens
      bucket["cacheReadInputTokens"] += cache_read
      bucket["cacheCreationInputTokens"] += cache_write

      if day in acc["recent"]:
        acc["recent"][day] += total

      if day == today:
        acc["todayPrompts"] += 1
        acc["todaySessions"].add(session_key)
        acc["todayTotalTokens"] += total
        acc["todayTokensByModel"][model] = acc["todayTokensByModel"].get(model, 0) + total
  except sqlite3.Error:
    return None
  finally:
    conn.close()

  return build_stats(acc, today, recent_dates)


def main():
  parser = argparse.ArgumentParser()
  parser.add_argument("provider")
  parser.add_argument("--force", action="store_true")
  args = parser.parse_args()

  today = datetime.now().strftime("%Y-%m-%d")
  cache_file = cache_path(args.provider)
  if not args.force:
    cached = read_fresh_cache(cache_file, today)
    if cached is not None:
      print(json.dumps(cached, separators=(",", ":")))
      return 0

  result = scan(args.provider)
  if result is None:
    return 1
  write_cache(cache_file, today, result)
  print(json.dumps(result, separators=(",", ":")))
  return 0


if __name__ == "__main__":
  sys.exit(main())