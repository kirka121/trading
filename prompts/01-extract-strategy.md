# Strategy Extraction Prompt

Answer these questions precisely — do not invent details that aren't in the transcripts:

1. **What indicators do they use?**
   List each one, what settings they use (if mentioned), and what they use it for.

2. **What conditions define a valid entry?**
   What specific things need to be true before they would enter a trade?
   Separate LONG entries from SHORT entries.

3. **What makes them avoid a trade?**
   What red flags do they explicitly mention? What conditions make them stay out?

4. **How do they manage risk?**
   Position sizing, stop loss placement, take profit targets — what do they say?

5. **What timeframes do they use?**
   Higher timeframe for bias, lower timeframe for entry?

Once you have extracted the strategy, format it as a `rules.json` file using this exact structure:

```json
{
  "watchlist": ["SPY"],

  "active_strategy": "[strategy_key]",

  "strategies": {
    "[strategy_key]": {
      "name": "[strategy name]",
      "sources": ["[trader name and handle]"],
      "description": "[one paragraph — what this strategy does and when it fires]",

      "default_timeframe": "4H",

      "indicators": {
        "[indicator_key]": "[what it tells you]"
      },
      "bias_criteria": {
        "bullish": ["condition 1", "condition 2"],
        "bearish": ["condition 1", "condition 2"],
        "neutral": ["condition 1"]
      },
      "entry_rules": {
        "long": ["condition 1", "condition 2"],
        "short": ["condition 1", "condition 2"]
      },
      "exit_rules": ["rule 1", "rule 2"],
      "risk_rules": ["rule 1", "rule 2"],
      "notes": ""
    }
  }
}
```

Notes on the structure:

- `watchlist` is top-level and shared across strategies. Whichever strategy is active is applied to every symbol in the watchlist.
- `strategies` is keyed by a short identifier (e.g. `vwap_rsi_ema`, `vdp_btc_swing`). Use snake_case.
- `active_strategy` selects which one runs. The `ACTIVE_STRATEGY` env var overrides it.
- Each strategy carries its own `default_timeframe` so different strategies (e.g. 4H swing vs. 5m intraday) can coexist in the same file.
- If `rules.json` already exists with other strategies, ADD this strategy as a new key under `strategies` (and update the watchlist if the user wants new symbols) instead of overwriting the file. Update `active_strategy` only if the user wants this new one to be the default.

Save the output as `rules.json` in the current directory.

---

[PASTE TRANSCRIPT CONTENT BELOW THIS LINE]
