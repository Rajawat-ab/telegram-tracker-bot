# Telegram Expense & Habit Tracker

[![Tests](https://github.com/Rajawat-ab/telegram-tracker-bot/actions/workflows/test.yml/badge.svg)](https://github.com/Rajawat-ab/telegram-tracker-bot/actions/workflows/test.yml)

Text your own Telegram bot like you'd text a friend. It logs spending and habits to CSV
files in a private GitHub repo, replies with running totals and streaks, nudges you about open
habits at 9 pm and sends a weekly recap with charts on Sunday. Everything runs on free tiers.

**[See the functional and architecture diagrams →](https://rajawat-ab.github.io/telegram-tracker-bot/)**

> This is the public copy of a bot I run daily from a private repo. The data files here are
> empty on purpose; to run your own, follow [Setup](#setup) in a **private** copy.

**Built with:** R · GitHub Actions · Cloudflare Workers + Durable Objects · Telegram Bot API.
**Highlights:** replies in about a minute from a webhook-triggered job; replies only after data
is saved; replay-safe processing (nothing logged twice, even `/undo`); a 2-hour backup schedule;
owner-only filtering at the edge; 63 automated tests in CI; ₹0 a month to run.

## How it works

```
                 ┌──────────── fast mode (about 1 min) ────────────┐
You ─▶ Telegram ─┤                                                  ▼
                 │   Cloudflare relay: stores the message, reacts 👀, starts the job
                 │                                                  │
                 └── schedule mode: the job asks Telegram itself ───┤
                                                                    ▼
        GitHub Actions "Tracker bot" (R):
          1. read new messages            (skips anything already saved)
          2. update data/*.csv            (+ the 9 pm nudge / Sunday recap when due)
          3. git push data/               (retries, pulls first if needed)
          4. send replies, react 👍        (only after the push succeeded)
          5. confirm the messages         (relay / Telegram forgets them)
```

**Why it can't lose or double-count anything**

- A message is only confirmed after the data is pushed. If any step fails, the message
  stays waiting and the next run handles it.
- `data/state.json` stores the last handled update id. Anything at or below it is never
  processed again, so a re-run can't log the same thing twice or `/undo` twice.
- Every run, whatever started it, handles everything waiting, and sends any report that is
  due and not yet sent today. A late or skipped schedule only delays things.
- The relay keeps messages in a Durable Object (a small database), not in Telegram's 24-hour
  queue, so a GitHub outage delays replies but doesn't drop messages.
- Problems show up as a red run in the Actions tab, and GitHub emails you about it.

## What you can send

| You send | What happens |
|---|---|
| `250 lunch` | Logs ₹250, category guessed as food |
| `lunch 250`, `spent 250 on lunch`, `Rs 250 lunch`, `1,200 rent` | Same idea |
| `1.5k rent #bills` | `k` means thousand, `#tag` sets the category yourself |
| `chai 20 yesterday` | Logs it against yesterday |
| `done gym` | Logs a habit for today and tells you your streak |
| `done reading 30 min` | Habit with a note or amount |
| `done meditation yesterday` | Backfill a habit |
| `/today` `/week` `/month` | Summaries |
| `/habits` | Streaks and this week's counts |
| `/budget 20000` | Monthly budget, with warnings at 80% and 100% |
| `/undo` | Removes the last thing you logged |
| `/ping` | Checks the bot is alive |
| `/help` | Shows all of this in the chat |

👀 on your message = the relay has it. 👍 = saved, and the reply is threaded to your message.

## Setup

Setup is in two stages. Stage 1 alone is a complete, working bot. Stage 2 makes it fast.

### Stage 1: GitHub + Telegram (schedule mode, replies within 2 hours)

1. **Create the bot.** In Telegram, open **@BotFather**, send `/newbot`, and keep the token.
2. **Get your chat ID.** Message **@userinfobot** and copy the number after `Id`.
3. **Say hi to your bot**, so it has a message waiting.
4. **Create a private GitHub repo**, then **Add file → Upload files** and drag in everything
   inside this folder (including `.github`). Check that `.github/workflows` has 3 files.
5. **Add secrets** under Settings → Secrets and variables → Actions → *New repository secret*:
   `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`.
6. **Test:** Actions → *Tracker bot* → *Run workflow*. Your bot replies to the `hi`.
   The *Tests* workflow also runs by itself after the upload and should be green.

### Stage 2: Cloudflare relay (fast mode, about 1 minute)

1. **Cloudflare:** sign up (free), open *Workers & Pages* once so it creates your
   `*.workers.dev` subdomain, then copy your **Account ID** (right-hand side of the
   dashboard home).
2. **Cloudflare API token:** My Profile → API Tokens → Create Token → template
   **Edit Cloudflare Workers** → your account → Create.
3. **GitHub token for the relay:** GitHub → Settings → Developer settings → Fine-grained
   tokens → Generate. Repository access: *Only select repositories* → this repo.
   Permissions: **Actions: Read and write** (nothing else).
4. **Relay secret:** a random string of 32+ letters and digits. In PowerShell:
   `-join ((48..57)+(65..90)+(97..122) | Get-Random -Count 40 | % {[char]$_})`
5. **Add 4 more repository secrets:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`,
   `GH_DISPATCH_TOKEN`, `RELAY_SECRET`.
6. **Deploy:** Actions → *Deploy relay (Cloudflare)* → *Run workflow*. Open the finished run
   and copy the relay URL from its summary.
7. **Turn fast mode on:** Settings → Secrets and variables → Actions → **Variables** tab →
   *New repository variable* `RELAY_URL` = that URL.
8. **Run the deploy again.** It confirms that the relay can start the bot. Then send `/ping`.

**Going back to schedule mode:** delete the `RELAY_URL` variable, then send this once from
any machine (replacing the two values):
`curl -X POST -H "Authorization: Bearer <RELAY_SECRET>" <RELAY_URL>/admin/unregister`

## Testing it

- `Tracker bot` → *Run workflow* with **force_reports** ticked sends the nudge and weekly recap
  right away, without affecting the real ones.
- `<RELAY_URL>/admin/status` (with the `Authorization: Bearer` header) shows the webhook,
  how many messages are waiting, and whether the last run start worked.
- The *Tests* workflow runs the R tests, the relay tests and a shell script check.

## Free-tier budget

| Item | Approx. minutes/month |
|---|---|
| Backup check every 2 h (finishes in seconds when idle, billed as 1 min) | ~360 |
| Runs started by your messages (~1.5–2 min each; messages close together share a run) | ~300–700 |
| Nudge + weekly recap | ~70 |
| **Total** | **~750–1,150 of 2,000** |

Cloudflare's free plan (100k requests/day) and the Telegram API cost nothing at this scale.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Red run: "Telegram said: Unauthorized" | `TELEGRAM_BOT_TOKEN` is wrong |
| Red run: "...webhook..." | The relay is on, but `RELAY_URL` isn't set. Add the variable. |
| Red run: "The relay did not answer correctly" | `RELAY_URL` or `RELAY_SECRET` is wrong |
| 👀 appears but no reply within ~5 min | Open `/admin/status`. If `lastDispatch` shows 401/403/404, fix `GH_DISPATCH_TOKEN`, then run the deploy again. The 2-hour backup still catches up. |
| No 👀 at all | Run the deploy again (it re-registers the webhook) |
| The bot never replies to anything | `TELEGRAM_CHAT_ID` is wrong. Check it with @userinfobot. |
| Red ❌ on "Save data", error 403 | Settings → Actions → General → Workflow permissions → Read and write |

## Customising

- **Categories:** `CATEGORY_KEYWORDS` in `R/parse.R`.
- **Report times / timezone:** the `env:` block at the top of `.github/workflows/bot.yml`
  (and its two report `cron` lines, which are in UTC; IST = UTC + 5:30).
- **Currency:** `RUPEE` in `R/parse.R`.

## Files

| File | Job |
|---|---|
| `R/parse.R` | Understands messages like `250 lunch` and `done gym` |
| `R/store.R` | Settings, CSV/JSON storage, streak and spending maths |
| `R/commands.R` | Slash commands and the friendly replies |
| `R/bot.R` | Turns a batch of updates into saved data and replies (replay-safe) |
| `R/reports.R` | 9 pm nudge and Sunday recap with charts |
| `R/telegram.R` | Talks to Telegram and the relay |
| `R/run.R` | What the workflow runs: `process`, then `deliver` |
| `scripts/` | Pre-check (skips R when idle) and the safe data push |
| `worker/` | Cloudflare relay (JavaScript) and its tests |
| `.github/workflows/` | `bot.yml` (the bot), `deploy-relay.yml`, `test.yml` |
| `data/` | Your data: `expenses.csv`, `habits.csv`, `state.json` |
