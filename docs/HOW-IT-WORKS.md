# How it works

The technical side of [the README](../README.md). Claude Code runs `statusline.sh` on every update (and every `refreshInterval` seconds), passes the session as JSON on stdin, and shows whatever the script prints. The script reads all its fields in a single `jq` call and prints two lines.

## Data it reads

| Field | Used for |
|---|---|
| `model.display_name`, `effort.level` | Top line |
| `workspace.current_dir` | Folder name and `git` branch/dirty check |
| `context_window.total_input_tokens`, `context_window_size` | Ctx bar |
| `rate_limits.five_hour` / `seven_day` (`used_percentage`, `resets_at`) | 5h and 7d bars |
| `prompt_cache` (`warm`, `expires_at`, `ttl`, `recache_tokens_if_cold`) | 🔥 / ❄️ |

Missing fields make their segment drop out, never the whole line.

## The context bar

Auto-compaction fires at `window − min(max_output, 20000) − 13000` tokens, measured in the CLI (v2.1.267). For every current model that is `window − 33k`. The bar reads 100 % a further margin before that:

```
margin = min(50k, 15% of window)
budget = window − 33k − margin
Ctx %  = total_input_tokens / budget   (capped at 100)
```

| Window | Compaction at | Bar full at |
|---|---|---|
| 1M | 967k | 917k |
| 200k | 167k | 137k |

The bar works in tokens rather than `used_percentage` because that field is rounded to whole percent, which on a 1M window is 10k tokens per step. If the JSON has no window size it falls back to `used_percentage / 85 %`.

If you shrink the window with `CLAUDE_CODE_AUTO_COMPACT_WINDOW` or the `autoCompactWindow` setting, change `CTX_RESERVED` to match.

## The cold-cache number

❄️ shows `recache_tokens_if_cold` × the cache-write multiplier: 2× on the 1-hour TTL (Claude Code's default) and 1.25× on the 5-minute one (which applies in usage overage). It is the price of the next message in plain-input-token equivalents, not the size of the context. The multiplier follows `.ttl` instead of being hardcoded.

## Settings you can change

All at the top of the script:

| Variable | Default | Meaning |
|---|---|---|
| `WIDTH` | 10 | Bar width in characters |
| `CTX_RESERVED` | 33000 | Distance from window size to auto-compaction |
| `CTX_MARGIN_MAX` | 50000 | How early the Ctx bar reads full… |
| `CTX_MARGIN_PCT` | 15 | …capped at this share of small windows |
| `CTX_FALLBACK_PCT` | 85 | Used only when there's no window size |

Thresholds: bars are green below 50 %, yellow 50–75 %, and red above 75 %. The cache turns yellow under 15 minutes. The 7d reset time appears under 48 hours left or at 50 % used, and becomes a countdown under 12 hours.

## Portability

- **Colours:** with `COLORTERM=truecolor` the green/yellow/red are explicit RGB, because some palettes (Ghostty's default) render ANSI 31/32/33 almost identically. Other terminals get the plain ANSI codes.
- **Dates:** `date -r <epoch>` is macOS-only (GNU `-r` means a file's mtime), so the script falls back to `date -d @<epoch>` on Linux.
- **Git:** calls use `--no-optional-locks` so the status line never contends with a git command you're running.

## Screenshots

The images in `docs/img/` are generated from the real script with made-up session data:

```sh
python3 docs/generate-screenshots.py
```

It converts the ANSI output to HTML and screenshots it with headless Chrome (macOS app path). No dependencies beyond Python 3. Rerun it when the output changes.
