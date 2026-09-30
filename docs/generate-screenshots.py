#!/usr/bin/env python3
"""Regenerate the README screenshots from the real statusline.sh.

Runs the script against fixed, made-up session data, turns its ANSI colours
into HTML, and screenshots that with headless Chrome. Rerun it whenever the
script's output changes:

    python3 docs/generate-screenshots.py

macOS only (uses the Chrome app bundle). No dependencies beyond Python 3.
"""
import html
import json
import os
import re
import struct
import subprocess
import tempfile
import time
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "statusline.sh")
OUT = os.path.join(ROOT, "docs", "img")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# GitHub-dark-ish palette for the ANSI codes the script emits.
FG = {"31": "#f85149", "32": "#3fb950", "33": "#db9e18",
      "36": "#39c5cf", "94": "#58a6ff", "95": "#d2a8ff"}


def session(ctx_tokens=300_000, window=1_000_000, effort="high",
            five=62, five_left=5000, seven=55, seven_left=200_000,
            cache_warm=True, cache_left=2400, cold_tokens=120_000,
            model="Opus 5.5", cwd=None):
    now = int(time.time())
    return {
        "model": {"display_name": model},
        "effort": {"level": effort},
        "workspace": {"current_dir": cwd},
        "context_window": {"total_input_tokens": ctx_tokens,
                           "context_window_size": window},
        "rate_limits": {
            "five_hour": {"used_percentage": five, "resets_at": now + five_left},
            "seven_day": {"used_percentage": seven, "resets_at": now + seven_left},
        },
        "prompt_cache": {"warm": cache_warm, "expires_at": now + cache_left,
                         "ttl": "1h", "recache_tokens_if_cold": cold_tokens},
    }


def run(data):
    env = dict(os.environ, COLORTERM="truecolor")
    out = subprocess.run([SCRIPT], input=json.dumps(data), env=env,
                         capture_output=True, text=True, check=True).stdout
    return out.rstrip("\n").split("\n")


def ansi_to_html(s):
    """Convert the SGR codes statusline.sh uses into <span>s."""
    parts, color, bold = [], None, False
    for chunk in re.split(r"(\x1b\[[0-9;]*m)", s):
        m = re.fullmatch(r"\x1b\[([0-9;]*)m", chunk)
        if m:
            codes = m.group(1).split(";")
            if codes[:2] == ["38", "2"]:
                color = "#%02x%02x%02x" % tuple(int(c) for c in codes[2:5])
            for c in codes:
                if c in ("0", ""):
                    color, bold = None, False
                elif c == "1":
                    bold = True
                elif c in FG and codes[:2] != ["38", "2"]:
                    color = FG[c]
            continue
        if not chunk:
            continue
        style = ""
        if color:
            style += "color:%s;" % color
        if bold:
            style += "font-weight:700;"
        text = html.escape(chunk)
        parts.append('<span style="%s">%s</span>' % (style, text) if style else text)
    return "".join(parts)


def line_html(ansi, labels=None):
    """One status line. With labels, each ' | '-separated segment gets a
    caption underneath, so the picture explains itself."""
    if not labels:
        return '<div class="line">%s</div>' % ansi_to_html(ansi)
    segs = ansi.split(" | ")
    cells = []
    for i, seg in enumerate(segs):
        if i:
            cells.append('<div class="seg"><div>&nbsp;|&nbsp;</div></div>')
        label = labels[i] if i < len(labels) else ""
        cells.append('<div class="seg"><div>%s</div><div class="label">%s</div></div>'
                     % (ansi_to_html(seg), html.escape(label)))
    return '<div class="line labelled">%s</div>' % "".join(cells)


def page(rows):
    body = []
    for caption, ansi, labels in rows:
        cap = '<div class="caption">%s</div>' % html.escape(caption) if caption else ""
        body.append('<div class="row">%s%s</div>' % (cap, line_html(ansi, labels)))
    return """<!doctype html><meta charset="utf-8"><style>
html,body{margin:0;background:transparent}
.term{display:inline-block;margin:0;padding:18px 22px;border-radius:10px;
  background:#0d1117;color:#c9d1d9;font:15px/1.5 Menlo,"SF Mono",monospace;
  white-space:pre}
.term::before{content:"";display:block;height:12px;margin-bottom:14px;
  background:radial-gradient(circle at 6px 6px,#ff5f57 5px,transparent 6px),
    radial-gradient(circle at 26px 6px,#febc2e 5px,transparent 6px),
    radial-gradient(circle at 46px 6px,#28c840 5px,transparent 6px);
  background-repeat:no-repeat}
.row+.row{margin-top:10px}
.caption{font:12px/1.4 -apple-system,Helvetica,sans-serif;color:#8b949e;margin-bottom:2px}
.labelled{display:flex;align-items:flex-start}
.label{font:11px/1.3 -apple-system,Helvetica,sans-serif;color:#8b949e;
  border-top:1px solid #30363d;margin-top:3px;padding-top:3px;text-align:center;
  white-space:normal}
</style><div class="term">%s</div>""" % "".join(body)


# --- PNG trim: crop the transparent margin Chrome leaves around the card ---

def read_png(path):
    data = open(path, "rb").read()
    pos, idat, w = 8, b"", 0
    while pos < len(data):
        n, typ = struct.unpack(">I4s", data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + n]
        if typ == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", chunk[:10])
            assert depth == 8 and ctype == 6, "expected 8-bit RGBA"
        elif typ == b"IDAT":
            idat += chunk
        pos += 12 + n
    raw, stride, rows, prev = zlib.decompress(idat), w * 4, [], bytearray(w * 4)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for x in range(stride):
            a = line[x - 4] if x >= 4 else 0
            b, c = prev[x], prev[x - 4] if x >= 4 else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if pa <= pb and pa <= pc else b if pb <= pc else c
                line[x] = (line[x] + pr) & 255
        rows.append(line)
        prev = line
    return w, h, rows


def write_png(path, w, h, rows):
    raw = b"".join(b"\x00" + bytes(r) for r in rows)
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def trim(path):
    w, h, rows = read_png(path)
    ys = [y for y in range(h) if any(rows[y][3::4])]
    xs = [x for x in range(w) if any(rows[y][x * 4 + 3] for y in ys)]
    x0, x1, y0, y1 = xs[0], xs[-1] + 1, ys[0], ys[-1] + 1
    write_png(path, x1 - x0, y1 - y0, [r[x0 * 4:x1 * 4] for r in rows[y0:y1]])


def shoot(name, rows, width=1400, height=500):
    os.makedirs(OUT, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False) as f:
        f.write(page(rows))
    png = os.path.join(OUT, name + ".png")
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--force-device-scale-factor=2", "--default-background-color=00000000",
                    "--window-size=%d,%d" % (width, height), "--screenshot=" + png,
                    "file://" + f.name], check=True, capture_output=True)
    os.unlink(f.name)
    trim(png)
    print("wrote", os.path.relpath(png, ROOT))


def main():
    # A throwaway git repo with uncommitted changes, so the branch shows "main*".
    repo = os.path.join(tempfile.mkdtemp(), "my-project")
    os.makedirs(repo)
    subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True)
    open(os.path.join(repo, "notes.txt"), "w").write("x")
    s = lambda **kw: run(session(cwd=repo, **kw))

    l1, l2 = s()
    shoot("overview", [
        (None, l1, ["Model and effort", "Folder", "Git branch (* = unsaved changes)"]),
        (None, l2, ["Room left in the conversation", "5-hour limit, resets in 1h 23m",
                    "Weekly limit, resets Friday", "Memory kept warm for 40 more min"]),
    ])

    shoot("calm", [(None, line, None) for line in
                   s(effort="medium", ctx_tokens=60_000, five=12, seven=8, cache_left=3300)])

    shoot("busy", [(None, line, None) for line in
                   s(effort="max", ctx_tokens=800_000, five=90, five_left=560,
                     seven=81, seven_left=15_100, cache_left=3000)])

    shoot("cache", [
        ("Warm, plenty of time", s(cache_left=2700)[1], None),
        ("Warm, running out: send something within 8 minutes to keep it", s(cache_left=500)[1], None),
        ("Cold: the next message costs about 240k tokens", s(cache_warm=False, cache_left=-60)[1], None),
    ])

    shoot("context", [
        ("Early in a conversation", s(ctx_tokens=150_000, five=20, seven=10)[1], None),
        ("Getting full: time to wrap up", s(ctx_tokens=640_000, five=20, seven=10)[1], None),
        ("Full: start a new conversation (/clear) before Claude compacts it for you",
         s(ctx_tokens=917_000, five=20, seven=10)[1], None),
    ])


if __name__ == "__main__":
    main()
