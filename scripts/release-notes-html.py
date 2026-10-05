#!/usr/bin/env python3
"""Turn docs/release-notes/vX.md into the HTML snippet Sparkle shows in its
update window and Pelmet shows in About.

No DOCTYPE or <body>, so generate_appcast embeds it in the item's
<description> as CDATA. Handles what the notes use: the H1 (dropped, the
window already names the version), ## sections, "Fixed:" style labels,
bullets with wrapped lines, a leading > blockquote (the announcement box),
links, **bold**, `code` and #N issue links.

Usage: release-notes-html.py NOTES.md [OUT.html]   (stdout without OUT)
"""
import html
import re
import sys

ISSUES = "https://github.com/fif7y/pelmet/issues/"

# Light and dark both come from color-scheme, so the snippet follows the
# window it lands in. Accent = Pelmet's brand purple (SettingsView.accent).
CSS = """\
:root{color-scheme:light dark;--fg:#1d1d1f;--muted:#6e6e73;--accent:#6841ed;--tint:rgba(104,65,237,.09)}
@media (prefers-color-scheme:dark){:root{--fg:#f2f2f7;--muted:#98989f;--accent:#a28cf8;--tint:rgba(126,95,242,.2)}}
body{margin:0;padding:12px 16px 14px;font:13px/1.45 -apple-system,system-ui,sans-serif;color:var(--fg);-webkit-font-smoothing:antialiased}
h2{font-size:14px;font-weight:600;margin:16px 0 4px}
h3{font-size:11px;font-weight:600;letter-spacing:.04em;text-transform:uppercase;color:var(--muted);margin:14px 0 4px}
p{margin:0 0 8px}
ul{margin:0 0 8px;padding-left:18px}
li{margin:0 0 4px}
li::marker{color:var(--muted)}
a{color:var(--accent);text-decoration:none}
code{font:12px ui-monospace,monospace}
.announce{background:var(--tint);border-radius:10px;padding:10px 12px;margin:0 0 12px}
.announce p:last-child{margin:0}
.announce strong{color:var(--accent)}
body>:first-child{margin-top:0}"""


def inline(text: str) -> str:
    out = html.escape(text, quote=False)
    out = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", r'<a href="\2">\1</a>', out)
    out = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", out)
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    out = re.sub(r"(?<![\w/&])#(\d+)\b", rf'<a href="{ISSUES}\1">#\1</a>', out)
    return out


def blocks(md: str):
    """Yield (kind, lines) for each block, wrapped lines joined."""
    kind, buf = None, []
    for raw in md.splitlines() + [""]:
        line = raw.rstrip()
        if not line.strip():
            if buf:
                yield kind, buf
            kind, buf = None, []
            continue
        if line.startswith("- "):
            if kind != "ul":
                if buf:
                    yield kind, buf
                kind, buf = "ul", []
            buf.append(line[2:].strip())
        elif kind == "ul" and raw.startswith(("  ", "\t")):
            buf[-1] += " " + line.strip()
        elif line.startswith(">"):
            if kind not in (None, "quote"):
                yield kind, buf
                buf = []
            kind = "quote"
            buf.append(line.lstrip(">").strip())
        elif line.startswith("#"):
            if buf:
                yield kind, buf
            level = len(line) - len(line.lstrip("#"))
            yield f"h{level}", [line.lstrip("#").strip()]
            kind, buf = None, []
        else:
            if kind not in (None, "p"):
                yield kind, buf
                buf = []
            kind = "p"
            buf.append(line.strip())


def render(md: str) -> str:
    parts = [f"<style>{CSS}</style>"]
    for kind, lines in blocks(md):
        text = " ".join(lines)
        if kind == "h1":
            continue
        if kind == "p" and "Get beta releases" in text and "channel only" in text:
            continue  # the opt-in hint; anyone reading this already has betas on
        if kind == "h2" or kind == "h3":
            parts.append(f"<h2>{inline(text)}</h2>")
        elif kind == "ul":
            items = "".join(f"<li>{inline(i)}</li>" for i in lines)
            parts.append(f"<ul>{items}</ul>")
        elif kind == "quote":
            # a bare ">" line splits the box into paragraphs
            paras = " ".join(l or "\n" for l in lines).split("\n")
            body = "".join(f"<p>{inline(p.strip())}</p>" for p in paras if p.strip())
            parts.append(f'<div class="announce">{body}</div>')
        elif re.fullmatch(r"[^.!?]{1,24}:", text):
            parts.append(f"<h3>{inline(text[:-1])}</h3>")
        else:
            parts.append(f"<p>{inline(text)}</p>")
    return "\n".join(parts) + "\n"


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    out = render(open(sys.argv[1], encoding="utf-8").read())
    if len(sys.argv) == 3:
        open(sys.argv[2], "w", encoding="utf-8").write(out)
    else:
        sys.stdout.write(out)
