#!/usr/bin/env bash
# precheck.sh -- decides whether this run needs R at all, so idle runs finish in seconds.
# Writes work=true|false to $GITHUB_OUTPUT. Fails the run (red X + email from GitHub)
# when Telegram or the relay can't be reached, instead of silently seeing "no messages".
set -euo pipefail

STATE=data/state.json
LAST=$(jq -r '.last_update_id // 0' "$STATE")

# A fresh copy of this repo with no secrets yet: stay idle instead of failing every run.
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] && [ -z "${RELAY_URL:-}" ]; then
  echo "::notice::Bot not configured yet (no TELEGRAM_BOT_TOKEN secret). See the README to set it up."
  echo "work=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

if [ -n "${RELAY_URL:-}" ]; then
  SOURCE="relay"
  RESP=$(curl -sS --max-time 20 --retry 2 -H "Authorization: Bearer ${RELAY_SECRET:-}" \
    "${RELAY_URL%/}/inbox/count?after=${LAST}" || true)
  if [ "$(echo "$RESP" | jq -r '.ok' 2>/dev/null)" != "true" ]; then
    echo "::error::The relay did not answer correctly. Check the RELAY_URL variable and RELAY_SECRET secret. Response: ${RESP:0:200}"
    exit 1
  fi
  PENDING=$(echo "$RESP" | jq -r '.count')
else
  SOURCE="telegram"
  RESP=$(curl -sS --max-time 20 --retry 2 \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=$((LAST + 1))&limit=100&timeout=0" || true)
  if [ "$(echo "$RESP" | jq -r '.ok' 2>/dev/null)" != "true" ]; then
    DESC=$(echo "$RESP" | jq -r '.description // empty' 2>/dev/null || true)
    echo "::error::Telegram said: ${DESC:-no response}. Check the TELEGRAM_BOT_TOKEN secret. (If it mentions a webhook, set the RELAY_URL variable.)"
    exit 1
  fi
  PENDING=$(echo "$RESP" | jq '.result | length')
fi

# Reports due? Same rule as due_reports() in R/reports.R.
TODAY=$(TZ="$BOT_TZ" date +%F)
HOUR=$(TZ="$BOT_TZ" date +%-H)
WDAY=$(TZ="$BOT_TZ" date +%u)
LAST_NUDGE=$(jq -r '.last_nudge_date // ""' "$STATE")
LAST_WEEKLY=$(jq -r '.last_weekly_date // ""' "$STATE")
REPORTS="none"
if [ "$HOUR" -ge "$NUDGE_HOUR" ] && [ "$LAST_NUDGE" != "$TODAY" ]; then REPORTS="due"; fi
if [ "$WDAY" -eq "$WEEKLY_DAY" ] && [ "$HOUR" -ge "$WEEKLY_HOUR" ] && [ "$LAST_WEEKLY" != "$TODAY" ]; then REPORTS="due"; fi
if [ "${FORCE_REPORTS:-}" = "true" ]; then REPORTS="forced"; fi

WORK=false
if [ "$PENDING" -gt 0 ] || [ "$REPORTS" != "none" ]; then WORK=true; fi

echo "work=$WORK" >> "$GITHUB_OUTPUT"
echo "Source: $SOURCE | new messages: $PENDING | reports: $REPORTS | work: $WORK"
{
  echo "| Source | New messages | Reports | Runs R |"
  echo "|---|---|---|---|"
  echo "| $SOURCE | $PENDING | $REPORTS | $WORK |"
} >> "$GITHUB_STEP_SUMMARY"
