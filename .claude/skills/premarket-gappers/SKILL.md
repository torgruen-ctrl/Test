---
name: premarket-gappers
description: Scan US stocks for premarket gappers via the TradingView connector (gap > 5 %, price > $3, premarket volume > 50,000, top 10), attach news catalysts, save ./premarket_gappers_YYYY-MM-DD.json and print a one-line summary. Use when the user asks for premarket gappers, a gap scan, or runs /premarket-gappers.
---

# Premarket gappers scan

Run the scan exactly once per request. Do not re-run unless the user asks.

## Preconditions

- The TradingView connector tools (`mcp__TradingView__mcp-tv-run-screener`, `mcp__TradingView__mcp-tv-get-news`) must be available. If they are deferred, load them with ToolSearch. If they are not available at all, stop and tell the user; do not fall back to other data sources without asking.
- Check the current date and time (`date -u`). US premarket runs 04:00–09:30 ET (10:00–15:30 German time). On weekends, holidays or outside that window the screener returns the last session's premarket values; say so clearly in the reply and name the session date the data belongs to.

## Step 1 — Screener

Call `mcp__TradingView__mcp-tv-run-screener` with:

```json
{
  "market": "america",
  "symbol_types": ["stock"],
  "filters": {
    "premarket_gap": [5, null],
    "premarket_close": [3, null],
    "premarket_volume": [50000, null]
  },
  "columns": ["name", "exchange", "close", "premarket_close", "premarket_gap", "premarket_change", "premarket_volume"],
  "sort_by": "premarket_gap",
  "sort_order": "desc",
  "limit": 10
}
```

The screener's range filters are inclusive; drop any row where `premarket_gap <= 5`, `premarket_close <= 3` or `premarket_volume <= 50000` so the limits are strictly greater-than.

Field mapping for the output:
- `price` = `premarket_close`
- `gap_pct` = `premarket_gap`, rounded to 2 decimals
- `premarket_volume` = `premarket_volume` (integer)

If the screener call fails or returns no rows, save the file with an empty `gappers` list, print `Premarket Gappers: 0 names.` and explain why.

## Step 2 — News catalyst per symbol

For every remaining row, call `mcp__TradingView__mcp-tv-get-news` with `symbol` = the row's `symbol` (EXCHANGE:TICKER) and `limit` = 5. Make these calls in parallel.

- Only use headlines published within 24 hours before the premarket session's open (convert `published` unix time with `date -u -d @<ts>`). Older headlines do not count as today's catalyst.
- `headlines`: up to 2 relevant headline titles, copied verbatim.
- `catalyst`: one sentence summarising what the headlines say, without a trailing period. Use only the headlines; do not add facts, and do not claim certainty the headlines don't give. If a headline is a sector roundup that does not name this ticker explicitly, say that the link is unclear.
- If the call fails or there is no headline in the window: `catalyst` = null, `headlines` = []. Never abort the whole scan for one ticker.

## Step 3 — Save

Write `./premarket_gappers_YYYY-MM-DD.json` (UTC date of the scan) in the repository root with exactly this schema, ranks starting at 1 in gap order:

```json
{
  "scanned_at": "2026-01-01T12:00:00Z",
  "gappers": [
    {"rank": 1, "symbol": "AAPL", "price": 175.20, "gap_pct": 7.5, "premarket_volume": 1200000, "catalyst": "Beat Q1 earnings, raised FY guidance", "headlines": ["Apple Reports Strong Q1", "Analysts Boost Price Targets"]}
  ]
}
```

`symbol` is the bare ticker (without exchange prefix). `scanned_at` is the current UTC time in ISO 8601. Validate the file with `jq . <file>` before continuing.

## Step 4 — Summary

Print this line, generated from the saved file:

```bash
jq -r '"Premarket Gappers: \(.gappers|length) names. Top: " + ([.gappers[:3][] | "\(.symbol) (\(.gap_pct)%) — \(.catalyst // "no catalyst found")"] | join(", "))' premarket_gappers_YYYY-MM-DD.json
```

Then add brief notes on anything the user should double-check: stale (non-trading-day) data, tickers without a catalyst, a previous close below $3, contradictory fields (e.g. positive gap with negative `premarket_change`), and any ticker whose catalyst involves a company that could present a conflict of interest for you.

## Step 5 — Keep the result

The cloud container is temporary. Commit the JSON file and push it to the current branch so the result survives the session.
