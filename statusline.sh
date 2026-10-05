#!/bin/bash
# Claude Code status line. Input: session JSON on stdin.
input=$(cat)

eval "$(printf '%s' "$input" | jq -r '
  @sh "MODEL=\(.model.display_name)
       EFFORT=\(.effort.level // "")
       DIR=\(.workspace.current_dir)
       PCT=\(.context_window.used_percentage // 0 | floor)
       CTX_TOKENS=\(.context_window.total_input_tokens // 0 | floor)
       CTX_SIZE=\(.context_window.context_window_size // 0 | floor)
       FIVE_H=\(.rate_limits.five_hour.used_percentage as $v | if $v == null then "" else ($v|floor|tostring) end)
       FIVE_RESET=\(.rate_limits.five_hour.resets_at // "")
       SEVEN_D=\(.rate_limits.seven_day.used_percentage as $v | if $v == null then "" else ($v|floor|tostring) end)
       SEVEN_RESET=\(.rate_limits.seven_day.resets_at // "")
       CACHE_WARM=\(.prompt_cache.warm // false | tostring)
       CACHE_EXP=\(.prompt_cache.expires_at // "")
       CACHE_COLD_TOK=\(.prompt_cache.recache_tokens_if_cold // 0 | floor)
       CACHE_TTL=\(.prompt_cache.ttl // "")
       SESSION=\(.session_id // "")"
')"

# Optional quota log. Set CLAUDE_STATUSLINE_QUOTA_LOG to a file path and one
# tab-separated line (epoch, 5h %, 7d %, session id, dir, 7d reset epoch) is
# appended each time either percentage moves. Sessions refresh independently,
# so readings from two sessions can interleave a point apart; a reader should
# take the highest value per reset window, not the difference between lines. On a subscription the quota is the real cost, so
# this is what to measure a feature's price in. Several sessions can share the
# file; comparing against the last line keeps unchanged readings out.
if [ -n "$CLAUDE_STATUSLINE_QUOTA_LOG" ] && [ -n "$SEVEN_D" ]; then
  last=$(tail -n 1 "$CLAUDE_STATUSLINE_QUOTA_LOG" 2>/dev/null | cut -f2,3)
  if [ "$last" != "${FIVE_H}	${SEVEN_D}" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$FIVE_H" "$SEVEN_D" "$SESSION" "$DIR" "$SEVEN_RESET" \
      >> "$CLAUDE_STATUSLINE_QUOTA_LOG" 2>/dev/null
  fi
fi

RESET='\033[0m'; BOLD='\033[1m'
CYAN='\033[36m'; BLUE='\033[94m'; MAGENTA='\033[95m'

# The pressure colours are given as explicit RGB when the terminal supports it.
# Asking for ANSI 32/33/31 asks for "palette slot 2/3/1", and Ghostty's default
# palette renders those close enough that the three bars were indistinguishable.
# RGB leaves the palette out of it. Falls back to the old codes elsewhere.
case "$COLORTERM" in
  truecolor|24bit)
    GREEN='\033[38;2;63;185;80m'; YELLOW='\033[38;2;219;158;24m'; RED='\033[38;2;248;81;73m' ;;
  *)
    GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m' ;;
esac

WIDTH=10

# Where the Ctx bar reads 100%: 50k tokens short of auto-compaction, so there
# is room to /clear deliberately instead of being compacted mid-task.
#
# Measured in the CLI (v2.1.267): compaction fires at
# `window - min(max_output,20000) - 13000` tokens -- 33k below the window when
# max_output >= 20k, which every current model clears. Hence RESERVED. The
# window itself is the full context window unless CLAUDE_CODE_AUTO_COMPACT_WINDOW
# or the autoCompactWindow setting shrinks it; neither is set here.
CTX_RESERVED=33000       # window - this = where auto-compaction fires
CTX_MARGIN_MAX=50000     # ... and this much earlier is where the bar reads full
CTX_MARGIN_PCT=15        # ... but never more than this share of a small window
CTX_FALLBACK_PCT=85      # used only if the JSON carries no window size

# bar <percent> -> coloured bar, green/yellow/red by pressure
bar() {
  local pct=$1 color filled
  if   [ "$pct" -gt 75 ]; then color="$RED"
  elif [ "$pct" -ge 50 ]; then color="$YELLOW"
  else                        color="$GREEN"; fi
  filled=$(( pct * WIDTH / 100 ))
  [ "$filled" -gt "$WIDTH" ] && filled=$WIDTH
  [ "$filled" -lt 0 ] && filled=0
  local f e; printf -v f "%${filled}s"; printf -v e "%$(( WIDTH - filled ))s"
  printf "%b%s%b" "$color" "${f// /█}${e// /░}" "$RESET"
}

# Line 1: model, directory, branch (* when dirty)
BRANCH=$(git -C "$DIR" --no-optional-locks branch --show-current 2>/dev/null)
if [ -n "$BRANCH" ]; then
  [ -n "$(git -C "$DIR" --no-optional-locks status --porcelain 2>/dev/null)" ] && BRANCH="$BRANCH*"
  BRANCH=" | ${GREEN}🌿 ${BRANCH}${RESET}"
fi
# Effort level, shown next to the model. Coloured on the same green/yellow/red
# pressure scale as the bars, since heavier effort is what burns the budget.
EFFORT_SEG=""
if [ -n "$EFFORT" ]; then
  case "$EFFORT" in
    low|medium) EFFORT_COLOR="$GREEN" ;;
    high)       EFFORT_COLOR="$YELLOW" ;;
    xhigh|max)  EFFORT_COLOR="$RED" ;;
    *)          EFFORT_COLOR="$CYAN" ;;
  esac
  EFFORT_SEG=$(printf " %b%s%b" "$EFFORT_COLOR" "$EFFORT" "$RESET")
fi
printf "${CYAN}[%s]${RESET}%b | ${BLUE}📁 %s${RESET}%b\n" "$MODEL" "$EFFORT_SEG" "${DIR##*/}" "$BRANCH"

# Time left until the 5h window resets, as (Xh XXm). Dropped when the
# timestamp is missing or already past.
COUNTDOWN=""
if [ -n "$FIVE_RESET" ]; then
  LEFT=$(( FIVE_RESET - $(date +%s) ))
  [ "$LEFT" -gt 0 ] && COUNTDOWN=$(printf " ${MAGENTA}(%dh %02dm)${RESET}" \
    $(( LEFT / 3600 )) $(( (LEFT % 3600) / 60 )))
fi

# When the 7d window resets. Only shown when it matters: less than 2 days
# left, or the window is already half spent. Under 12 hours the absolute
# (day HH:MM) stops being useful, so it flips to a countdown: (in HH:MM).
SEVEN_WHEN=""
if [ -n "$SEVEN_RESET" ]; then
  LEFT7=$(( SEVEN_RESET - $(date +%s) ))
  if [ "$LEFT7" -gt 0 ] && { [ "$LEFT7" -lt 172800 ] || [ "${SEVEN_D:-0}" -ge 50 ]; }; then
    if [ "$LEFT7" -lt 43200 ]; then
      SEVEN_WHEN=$(printf " ${MAGENTA}(in %02d:%02d)${RESET}" \
        $(( LEFT7 / 3600 )) $(( (LEFT7 % 3600) / 60 )))
    else
      SEVEN_WHEN=$(printf " ${MAGENTA}(%s)${RESET}" \
        "$( { LC_TIME=C date -r "$SEVEN_RESET" '+%a %H:%M' 2>/dev/null || LC_TIME=C date -d "@$SEVEN_RESET" '+%a %H:%M'; } | tr '[:upper:]' '[:lower:]')")
    fi
  fi
fi

# Prompt-cache state. The session JSON carries a whole .prompt_cache block
# (measured on v2.1.276): .warm, .ttl, .expires_at as an epoch, and
# .recache_tokens_if_cold -- what a cold start would have to re-send.
#
# Warm: how long the cache still lives, green above 15 minutes, yellow below.
# Cold (expired, or never written): red, with the token bill for the next
# message. Missing block = no API response yet, so the segment drops out.
#
# The cold number is the BILL, not the context size: re-sending a cold prefix
# is charged as a cache write, which costs 2x base input on the 1h TTL and
# 1.25x on the 5m one. So a 100k context reads "200k" -- what the next message
# costs in plain-input-token equivalents. The multiplier follows .ttl rather
# than being hardcoded, because the TTL drops to 5m when the account is in
# usage overage, and the bill drops with it.
CACHE_SEG=""
if [ -n "$CACHE_EXP" ]; then
  CACHE_LEFT=$(( CACHE_EXP - $(date +%s) ))
  if [ "$CACHE_WARM" = "true" ] && [ "$CACHE_LEFT" -gt 0 ]; then
    if [ "$CACHE_LEFT" -ge 3600 ]; then
      CACHE_TXT=$(printf "%dh%02dm" $(( CACHE_LEFT / 3600 )) $(( (CACHE_LEFT % 3600) / 60 )))
    else
      CACHE_TXT=$(printf "%dm" $(( CACHE_LEFT / 60 )))
    fi
    [ "$CACHE_LEFT" -ge 900 ] && CACHE_COLOR="$GREEN" || CACHE_COLOR="$YELLOW"
    CACHE_SEG=$(printf " | %b🔥 %s%b" "$CACHE_COLOR" "$CACHE_TXT" "$RESET")
  else
    case "$CACHE_TTL" in
      5m|5M|300|300s) CACHE_MULT=125 ;;   # 5-minute TTL: write costs 1.25x
      *)              CACHE_MULT=200 ;;   # 1-hour TTL (Claude Code default): 2x
    esac
    CACHE_BILL=$(( CACHE_COLD_TOK * CACHE_MULT / 100 ))
    CACHE_SEG=$(printf " | %b❄️ %dk%b" "$RED" $(( (CACHE_BILL + 500) / 1000 )) "$RESET")
  fi
fi

# Line 2: Ctx / 5h / 7d bars. Rate limits are absent for non-subscribers
# and before the first API response, so those segments drop out entirely.
# Ctx counts against the budget above, so bar and number both read "share of
# the context I can still safely use" and hit 100% 50k tokens before compaction.
# Done in tokens, not on used_percentage: that field is rounded to whole
# percent, which on a 1M window is 10k tokens of slack per step.
CTX_MARGIN=$(( CTX_SIZE * CTX_MARGIN_PCT / 100 ))
[ "$CTX_MARGIN" -gt "$CTX_MARGIN_MAX" ] && CTX_MARGIN=$CTX_MARGIN_MAX
CTX_BUDGET=$(( CTX_SIZE - CTX_RESERVED - CTX_MARGIN ))
if [ "$CTX_BUDGET" -gt 0 ]; then
  CTX_PCT=$(( CTX_TOKENS * 100 / CTX_BUDGET ))
else
  CTX_PCT=$(( PCT * 100 / CTX_FALLBACK_PCT ))
fi
[ "$CTX_PCT" -gt 100 ] && CTX_PCT=100
LINE2="${BOLD}Ctx${RESET} $(bar "$CTX_PCT") ${BOLD}${CTX_PCT}%${RESET}"
[ -n "$FIVE_H" ]  && LINE2="${LINE2} | ${BOLD}5h${RESET}${COUNTDOWN} $(bar "$FIVE_H") ${BOLD}${FIVE_H}%${RESET}"
[ -n "$SEVEN_D" ] && LINE2="${LINE2} | ${BOLD}7d${RESET}${SEVEN_WHEN} $(bar "$SEVEN_D") ${BOLD}${SEVEN_D}%${RESET}"
printf "%b%b\n" "$LINE2" "$CACHE_SEG"
