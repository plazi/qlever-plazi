#!/usr/bin/env bash
# status-badge.sh STATUS_JSON: prints an SVG badge for the Upptime board,
# e.g. "qlever | 891,091 treatments · 100% of LINDAS · 1d"
set -euo pipefail

status=$1
label=qlever
read -r healthy count ratio age < <(jq -r '[.healthy, (.treatments.live // "?"), (.treatments.ratio // "?"), (.index_age_hours // "?")] | @tsv' "$status")

fmt_count=$(printf "%'d" "$count" 2>/dev/null || echo "$count")
[ "$count" = "?" ] && fmt_count="?"
pct=$([ "$ratio" = "?" ] && echo "?" || awk -v r="$ratio" 'BEGIN { printf "%d%%", r * 100 + 0.5 }')
if [ "$age" = "?" ]; then age_txt="?"; elif [ "$age" -lt 48 ]; then age_txt="${age}h"; else age_txt="$((age / 24))d"; fi
text="$fmt_count treatments · $pct of LINDAS · $age_txt old"
color=$([ "$healthy" = true ] && echo "#2ea44f" || echo "#d73a49")

# Verdana 11px averages about 6.5px per character
lw=$(( ${#label} * 7 + 12 ))
tw=$(( $(printf '%s' "$text" | wc -m) * 13 / 2 + 12 ))
w=$(( lw + tw ))
cat <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="20" role="img" aria-label="$label: $text">
  <title>$label: $text</title>
  <rect width="$lw" height="20" fill="#555"/>
  <rect x="$lw" width="$tw" height="20" fill="$color"/>
  <g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="11">
    <text x="$(( lw / 2 ))" y="14">$label</text>
    <text x="$(( lw + tw / 2 ))" y="14">$text</text>
  </g>
</svg>
SVG
