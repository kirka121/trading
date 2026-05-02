---
description: Launch TradingView with the watchlist + active strategy, then start the bot.
---

End-to-end "go" command. You will:

1. **Launch TradingView Desktop** with CDP enabled.
2. **Sync the user's `###BOT` watchlist section to exactly the rules.json watchlist** — silent (no popups), idempotent.
3. **Start the bot loop** so it trades on the same cadence as the strategy's timeframe.

## Step 1 — Read the config

Read `rules.json`. Pull out:

- `watchlist` — array of objects, each shaped `{ "questrade": "...", "tv": "..." }`. The Questrade symbol is what the bot uses to fetch market data and place orders; the TV symbol is what TradingView understands. They differ for cross-listed names (e.g. `VSP.TO` ↔ `VSP`). When this slash command interacts with TradingView, **use only the `tv` field**.
- `active_strategy` — the strategy key (or `"all"` to run every registered strategy).
- `strategies[active_strategy].name` — for the announcement (or just the count when "all").

Announce to the user, in one line: `Running <strategy name> on <N> symbols.`

## Step 2 — Launch TradingView

Run `bin/launch_tv` via Bash. It kills any running TV instance and re-launches with `--remote-debugging-port=9222` so the TradingView MCP server can connect. Wait for the script to print "CDP ready" before continuing.

If launch fails (TV not installed, CDP doesn't come up), stop and tell the user — don't proceed to step 3.

## Step 3 — Sync the ###BOT watchlist section

Build the symbol array by mapping each rules.json watchlist entry to its `tv` field (NOT `questrade` — TV doesn't understand `VSP.TO`, it wants `VSP`). Then single call:

```
mcp__tradingview__watchlist_sync_bot_section { "symbols": [<rules.json watchlist .map(e -> e.tv)>] }
```

This makes the contents of the user's `###BOT` watchlist section equal to the rules.json watchlist exactly: symbols already there are skipped (no UI activity), missing ones are added silently via TV's internal `addToWatchlist._execute()`, extras are removed by clicking the row's hidden remove-button. Idempotent.

If the response includes a `warning` (e.g. `###BOT is not the last section`), surface it but continue. If `errors` is non-empty, list them in the final summary.

End with: `BOT section: kept N, added X, removed Y.`

## Step 4 — Start the bot

Run the bot in background (run_in_background: true):

```
bin/bot
```

The bot will produce a run every T time, then sleep. It will tell us how long it will sleep for before the next run in its output.
From this point on every time bot completes its run, show the output in claude's session window (so the user can see it).
After each run finishes, consult rules.json to check if there are any strong BUY or SELL signals, highlight them in GREEN and RED respectively. Keep running indefinitely until stopped. Avoid prompting user for any inputs, because this terminal window may be setup as a monitor without an easy way to respond.

## Notes

- Don't ask the user to confirm between steps — run the whole flow start to finish.
- The user must have a `###BOT` section in their watchlist, and it must be the LAST section. Silent adds always append to the end of the symbols array, so they only land inside `###BOT` when no section follows it. The sync tool reports a `warning` if this assumption is broken.
