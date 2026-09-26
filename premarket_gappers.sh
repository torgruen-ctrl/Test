#!/usr/bin/env bash
# Premarket gappers scanner.
#
# WebFetch is a Claude Code tool, not a CLI program, so every fetch runs through
# headless Claude Code (`claude -p`) with only the WebFetch tool allowed.
# Filtering, sorting and JSON assembly are done deterministically with jq.
#
# Requirements: claude (Claude Code CLI, logged in), jq, bash 4+.
# Usage: ./premarket_gappers.sh            (writes ./premarket_gappers_YYYY-MM-DD.json)
# Env:   CLAUDE_MODEL=<model id>           optional model override for the fetch calls
#        LOOKUP_TIMEOUT=<seconds>          per-call timeout (default 120)

set -euo pipefail

YAHOO_URL="https://finance.yahoo.com/markets/stocks/gainers/"
MAX_NAMES=10
LOOKUP_TIMEOUT="${LOOKUP_TIMEOUT:-120}"
OUT="./premarket_gappers_$(date +%F).json"

for bin in claude jq timeout; do
  command -v "$bin" >/dev/null || { echo "error: '$bin' not found in PATH" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

model_args=()
[[ -n "${CLAUDE_MODEL:-}" ]] && model_args=(--model "$CLAUDE_MODEL")

# Run one headless Claude call restricted to WebFetch; print the model's final text.
claude_fetch() {
  timeout "$LOOKUP_TIMEOUT" claude -p "$1" \
    --allowedTools WebFetch --max-turns 4 --output-format json "${model_args[@]}" \
    2>/dev/null | jq -r '.result // empty'
}

# Pull the JSON value out of model text (tolerates ``` fences and surrounding prose):
# take the span from the first '[' or '{' to the last ']' or '}' and parse it.
extract_json() {
  jq -R -s -c '
    (  [index("["), index("{")] | map(select(. != null)) | min) as $a
    | ([rindex("]"), rindex("}")] | map(select(. != null)) | max) as $b
    | if $a == null or $b == null or $b < $a then empty
      else (.[$a:$b+1] | fromjson? // empty) end' 2>/dev/null
}

# 1) Gainers table -----------------------------------------------------------
yahoo_prompt="Use the WebFetch tool on ${YAHOO_URL} with the prompt: \"Return every row of the stock gainers table: symbol, price, percent change, volume.\"
Then output ONLY a JSON array, no prose, no code fences. One object per row:
{\"symbol\": string, \"price\": number, \"gap_pct\": number, \"premarket_volume\": integer}
gap_pct is the percent-change column as a plain number (\"+12.34%\" -> 12.34).
premarket_volume is the volume column as an integer (\"1.2M\" -> 1200000, \"850K\" -> 850000).
Copy numbers exactly as shown on the page; do not estimate. If the fetch fails, output []."

rows="$(claude_fetch "$yahoo_prompt" | extract_json || true)"
if [[ -z "$rows" ]] || ! jq -e 'type=="array"' <<<"$rows" >/dev/null; then
  echo "error: could not fetch or parse the Yahoo gainers table" >&2
  exit 1
fi

# 2) Filter + rank (deterministic, not left to the model) ----------------------
top="$(jq -c --argjson n "$MAX_NAMES" '
  map(select((.symbol|type)=="string"
             and (.price|type)=="number"
             and (.gap_pct|type)=="number"
             and (.premarket_volume|type)=="number"))
  | map(select(.gap_pct > 5 and .price > 3 and .premarket_volume > 50000))
  | unique_by(.symbol)
  | sort_by(-.gap_pct)
  | .[:$n]' <<<"$rows")"

# 3) Catalyst lookups in parallel (keeps runtime ~60-90s) ----------------------
mapfile -t symbols < <(jq -r '.[].symbol' <<<"$top")
for sym in "${symbols[@]}"; do
  (
    bz_prompt="Use the WebFetch tool on https://www.benzinga.com/quote/${sym} with exactly this prompt: \"What recent news or catalyst is driving ${sym} stock today? Return a one-sentence summary, then up to 2 recent headlines verbatim. Just the data — no commentary.\"
Then output ONLY this JSON object, no prose, no code fences:
{\"catalyst\": string or null, \"headlines\": [up to 2 strings copied verbatim]}
If the fetch fails or the page has no relevant news, output {\"catalyst\": null, \"headlines\": []}."
    res="$(claude_fetch "$bz_prompt" | extract_json || true)"
    if jq -e 'type=="object"' <<<"${res:-null}" >/dev/null 2>&1; then
      jq -c '{catalyst: (if (.catalyst|type)=="string" and (.catalyst|length)>0 then .catalyst else null end),
              headlines: ([.headlines[]? | select(type=="string")] | .[:2])}' <<<"$res" \
        > "$WORK/$sym.json" 2>/dev/null || echo '{"catalyst":null,"headlines":[]}' > "$WORK/$sym.json"
    else
      echo '{"catalyst":null,"headlines":[]}' > "$WORK/$sym.json"
    fi
  ) &
done
wait

# 4) Assemble output ------------------------------------------------------------
cat_map='{}'
for sym in "${symbols[@]}"; do
  f="$WORK/$sym.json"
  [[ -s "$f" ]] || echo '{"catalyst":null,"headlines":[]}' > "$f"
  cat_map="$(jq -c --arg s "$sym" --slurpfile c "$f" '. + {($s): $c[0]}' <<<"$cat_map")"
done

jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson top "$top" --argjson cats "$cat_map" '
  {scanned_at: $ts,
   gappers: [ $top | to_entries[] | {
     rank: (.key + 1),
     symbol: .value.symbol,
     price: .value.price,
     gap_pct: .value.gap_pct,
     premarket_volume: (.value.premarket_volume | floor),
     catalyst: ($cats[.value.symbol].catalyst // null),
     headlines: ($cats[.value.symbol].headlines // [])
   }]}' > "$OUT"

# 5) One-line summary -------------------------------------------------------------
jq -r '
  "Premarket Gappers: \(.gappers|length) names. Top: " +
  ( [ .gappers[:3][] | "\(.symbol) (\(.gap_pct)%) — \(.catalyst // "no catalyst found")" ] | join(", ") )' "$OUT"
