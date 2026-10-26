#!/usr/bin/env python3
"""Validate docs/ and render the GitHub Pages site into _site/.

Everything here uses the Python standard library only: there is no third-party
render dependency (the `markdown` package was removed; the small renderer
below covers the Markdown subset the docs actually use). `--check` and the
default render therefore run with a bare `python3`.

Checks (always):
  * every relative link in every docs/*.md resolves to a file in docs/
  * every docs/*.md is linked from docs/index.md
  * every docs/*.md is listed in docs/llms.txt
  * every page has a level-1 heading (the HTML <title>)

Render (default):
  * _site/<name>.html   rendered page (links rewritten .md -> .html)
  * _site/<name>.md     raw markdown copy (machine readers fetch this)
  * _site/llms.txt      raw copy
  * then every rendered fragment link (page#id) must resolve

Heading ids keep their Unicode text (slugify_unicode-compatible), so Japanese
headings are linkable as-is instead of turning into `_1`, `_2`, ...

Usage:
  python3 docs/build.py           check + render
  python3 docs/build.py --check   check only
"""

import html
import re
import shutil
import sys
import unicodedata
from pathlib import Path

DOCS = Path(__file__).resolve().parent
SITE = DOCS.parent / "_site"
LLMS = DOCS / "llms.txt"

LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+?)(?:\s+\"[^\"]*\")?\)")
HEADING_RE = re.compile(r"^# (.+)$", re.MULTILINE)

STYLE = """\
:root { color-scheme: light dark; }
* { box-sizing: border-box; }
body { margin: 0; padding: 0 1rem 4rem;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Hiragino Sans",
    "Noto Sans CJK JP", sans-serif;
  line-height: 1.7; }
main { max-width: 46rem; margin: 0 auto; padding-top: 2rem; }
pre, code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.9em; }
pre { overflow-x: auto; padding: 0.75rem 1rem; border: 1px solid #8884;
  border-radius: 6px; background: #8881; }
code { padding: 0.1em 0.3em; background: #8882; border-radius: 4px; }
pre code { padding: 0; background: none; }
table { border-collapse: collapse; width: 100%; margin: 1rem 0; }
th, td { border: 1px solid #8886; padding: 0.4rem 0.6rem; text-align: left;
  vertical-align: top; }
th { background: #8882; }
h1, h2, h3 { line-height: 1.3; }
h1 { border-bottom: 2px solid #8886; padding-bottom: 0.3rem; }
h2 { border-bottom: 1px solid #8884; padding-bottom: 0.2rem; margin-top: 2rem; }
a { color: #3b82f6; }
hr { border: none; border-top: 1px solid #8886; margin: 2rem 0; }
footer { max-width: 46rem; margin: 3rem auto 0; padding-top: 1rem;
  border-top: 1px solid #8886; font-size: 0.85em; opacity: 0.8; }
"""

TEMPLATE = """\
<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
{style}</style>
</head>
<body>
<main>
{body}
</main>
<footer>
<a href="{raw}">{raw}</a>（機械可読の Markdown 原文）・
<a href="index.html">目次</a>
</footer>
</body>
</html>
"""


def collect_markdown_files():
    return sorted(DOCS.glob("*.md"))


def page_title(text):
    match = HEADING_RE.search(text)
    if not match:
        return None
    return match.group(1).strip()


def link_targets(text):
    return [m.group(1) for m in LINK_RE.finditer(text)]


def check_links(md_files, errors):
    for md in md_files:
        for target in link_targets(md.read_text(encoding="utf-8")):
            if re.match(r"^[a-z][a-z0-9+.-]*:", target) or target.startswith(("#", "/")):
                continue
            path = target.split("#", 1)[0]
            if not path:
                continue
            resolved = (md.parent / path).resolve()
            candidate = resolved
            if resolved.suffix == ".html":
                candidate = resolved.with_suffix(".md")
            if DOCS not in candidate.parents and candidate != DOCS:
                errors.append(f"{md.name}: link escapes docs/: {target}")
            elif not candidate.is_file():
                errors.append(f"{md.name}: broken link: {target}")


def check_index_links(md_files, errors):
    index = DOCS / "index.md"
    if not index.is_file():
        errors.append("index.md is missing")
        return
    linked = {t.split("#", 1)[0] for t in link_targets(index.read_text(encoding="utf-8"))}
    for md in md_files:
        if md.name == "index.md":
            continue
        if md.name not in linked:
            errors.append(f"index.md does not link to {md.name}")


def check_llms(md_files, errors):
    if not LLMS.is_file():
        errors.append("llms.txt is missing")
        return
    text = LLMS.read_text(encoding="utf-8")
    for md in md_files:
        if md.name not in text:
            errors.append(f"llms.txt does not list {md.name}")


def rewrite_md_links(body):
    def repl(match):
        href = match.group(1)
        if href.startswith(("http://", "https://", "mailto:", "#", "/")):
            return match.group(0)
        base, sep, frag = href.partition("#")
        if base.endswith(".md"):
            return f'href="{base[:-3]}.html{sep}{frag}"'
        return match.group(0)

    return re.sub(r'href="([^"]+)"', repl, body)


def slugify_unicode(value):
    """Match Python-Markdown's toc slugify_unicode for heading ids.

    Normalizes, removes punctuation/symbols (keeping word characters,
    whitespace and hyphens, including CJK), and collapses runs of whitespace
    or hyphens into a single hyphen.
    """
    value = unicodedata.normalize("NFKC", value)
    value = re.sub(r"[^\w\s-]", "", value.lower())
    return re.sub(r"[-\s]+", "-", value).strip("-_")


def heading_text(content):
    """Plain text of a heading (drop inline code/bold/link markup)."""
    content = re.sub(r"`([^`]+)`", r"\1", content)
    content = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", content)
    content = content.replace("**", "").replace("__", "")
    return re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"\1", content)


def _inline(text):
    """Render inline Markdown: escapes, code, bold/italic, links, autolinks."""
    tokens = {}

    def stash(rendered):
        key = f"\x00{len(tokens)}\x00"
        tokens[key] = rendered
        return key

    # Inline code first (its contents must not be re-parsed).
    def code_repl(match):
        return stash(f"<code>{html.escape(match.group(1).strip())}</code>")

    text = re.sub(r"`([^`]+)`", code_repl, text)

    # Autolinks <https://...> and <mailto:...>.
    def autolink(match):
        url = match.group(1)
        return stash(f'<a href="{html.escape(url, quote=True)}">{html.escape(url)}</a>')

    text = re.sub(r"<((?:https?|mailto):[^>\s]+)>", autolink, text)

    # Escape whatever is left as literal text.
    text = html.escape(text, quote=False)

    # Images ![alt](src) before links.
    def image_repl(match):
        alt, src = match.group(1), match.group(2)
        return stash(f'<img alt="{html.escape(alt, quote=True)}" '
                     f'src="{html.escape(src, quote=True)}">')

    text = re.sub(r"!\[([^\]]*)\]\(([^)\s]+)\)", image_repl, text)

    # Links [text](href "title").
    def link_repl(match):
        label, href, title = match.group(1), match.group(2), match.group(3)
        attr = f' title="{html.escape(title, quote=True)}"' if title else ""
        return stash(f'<a href="{html.escape(href, quote=True)}"{attr}>'
                     f"{_inline(label)}</a>")

    text = re.sub(
        r"\[([^\]]*)\]\(([^)\s]+?)(?:\s+\"([^\"]*)\")?\)", link_repl, text
    )

    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"<em>\1</em>", text)

    for key, rendered in tokens.items():
        text = text.replace(key, rendered)
    return text


def _is_table_sep(line):
    return bool(re.fullmatch(r"\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?", line.strip()))


def _split_row(line):
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|") and not line.endswith("\\|"):
        line = line[:-1]
    cells = []
    current = []
    escaped = False
    for char in line:
        if escaped:
            current.append(char if char == "|" else "\\" + char)
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == "|":
            cells.append("".join(current).strip())
            current = []
        else:
            current.append(char)
    if escaped:
        current.append("\\")
    cells.append("".join(current).strip())
    return cells


def render_markdown(text):
    """Render the Markdown subset used by docs/ to HTML (stdlib only)."""
    lines = text.split("\n")
    out = []
    paragraph = []
    i = 0
    n = len(lines)

    def flush_paragraph():
        if paragraph:
            out.append(f"<p>{_inline(' '.join(paragraph))}</p>\n")
            paragraph.clear()

    while i < n:
        line = lines[i]

        # Fenced code block.
        if re.match(r"^```", line):
            flush_paragraph()
            lang = line[3:].strip()
            i += 1
            code = []
            while i < n and not re.match(r"^```", lines[i]):
                code.append(lines[i])
                i += 1
            i += 1  # closing fence
            body = html.escape("\n".join(code), quote=False)
            cls = f' class="language-{html.escape(lang, quote=True)}"' if lang else ""
            out.append(f"<pre><code{cls}>{body}\n</code></pre>\n")
            continue

        # Heading.
        heading = re.match(r"^(#{1,6})\s+(.*?)\s*#*\s*$", line)
        if heading:
            flush_paragraph()
            level = len(heading.group(1))
            content = heading.group(2)
            slug = slugify_unicode(heading_text(content))
            out.append(f'<h{level} id="{html.escape(slug, quote=True)}">'
                       f"{_inline(content)}</h{level}>\n")
            i += 1
            continue

        # Horizontal rule.
        if re.fullmatch(r"(-{3,}|\*{3,}|_{3,})", line.strip()):
            flush_paragraph()
            out.append("<hr>\n")
            i += 1
            continue

        # Blockquote (contiguous lines).
        if line.startswith(">"):
            flush_paragraph()
            quote = []
            while i < n and lines[i].startswith(">"):
                quote.append(lines[i][1:].lstrip() if lines[i][1:2] == " " else lines[i][1:])
                i += 1
            out.append(f"<blockquote>\n{render_markdown(chr(10).join(quote))}</blockquote>\n")
            continue

        # Table.
        if "|" in line and i + 1 < n and _is_table_sep(lines[i + 1]):
            flush_paragraph()
            headers = _split_row(line)
            i += 2
            rows = []
            while i < n and lines[i].strip() and "|" in lines[i]:
                rows.append(_split_row(lines[i]))
                i += 1
            head = "".join(f"<th>{_inline(c)}</th>" for c in headers)
            body_rows = []
            for row in rows:
                cells = "".join(f"<td>{_inline(c)}</td>" for c in row)
                body_rows.append(f"<tr>{cells}</tr>")
            table = [f"<table>\n<thead>\n<tr>{head}</tr>\n</thead>"]
            if body_rows:
                table.append("<tbody>\n" + "\n".join(body_rows) + "\n</tbody>")
            table.append("</table>\n")
            out.append("\n".join(table))
            continue

        # Lists (unordered / ordered).
        list_match = re.match(r"^(\s*)([-*]|\d+\.)\s+(.*)$", line)
        if list_match:
            flush_paragraph()
            ordered = bool(re.match(r"\d+\.", list_match.group(2)))
            tag = "ol" if ordered else "ul"
            items = []
            while i < n:
                m = re.match(r"^(\s*)([-*]|\d+\.)\s+(.*)$", lines[i])
                if not m:
                    break
                marker_ordered = bool(re.match(r"\d+\.", m.group(2)))
                if marker_ordered != ordered:
                    break
                item = [m.group(3)]
                i += 1
                # Fold indented continuation lines into the same item.
                while i < n and lines[i].strip():
                    if re.match(r"^(\s*)([-*]|\d+\.)\s+", lines[i]):
                        break
                    if not lines[i].startswith(("  ", "\t")):
                        break
                    item.append(lines[i].strip())
                    i += 1
                items.append(" ".join(item))
            body = "".join(f"<li>{_inline(item)}</li>\n" for item in items)
            out.append(f"<{tag}>\n{body}</{tag}>\n")
            continue

        # Blank line ends a paragraph.
        if not line.strip():
            flush_paragraph()
            i += 1
            continue

        paragraph.append(line.strip())
        i += 1

    flush_paragraph()
    return "".join(out)


def render(md_files):
    if SITE.exists():
        shutil.rmtree(SITE)
    SITE.mkdir(parents=True)

    for md in md_files:
        text = md.read_text(encoding="utf-8")
        title = page_title(text) or md.name
        body = render_markdown(text)
        page = TEMPLATE.format(
            title=html.escape(title),
            style=STYLE,
            body=rewrite_md_links(body),
            raw=md.name,
        )
        (SITE / f"{md.stem}.html").write_text(page, encoding="utf-8")
        (SITE / md.name).write_text(text, encoding="utf-8")

    shutil.copyfile(LLMS, SITE / "llms.txt")
    errors = check_fragments()
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    if errors:
        return False
    print(f"rendered {len(md_files)} page(s) into {SITE}")
    return True


def check_fragments():
    """Every href with a fragment must land on a generated id (render only)."""
    pages = {p.name: p.read_text(encoding="utf-8") for p in SITE.glob("*.html")}
    ids = {name: set(re.findall(r'id="([^"]+)"', text)) for name, text in pages.items()}
    errors = []
    for name, text in pages.items():
        for href in re.findall(r'href="([^"]+)"', text):
            if href.startswith(("http://", "https://", "mailto:")):
                continue
            page, _, frag = href.partition("#")
            if page and page not in pages:
                if not (SITE / page).exists():
                    errors.append(f"{name}: link target missing: {href}")
                continue
            if frag and frag not in (ids.get(page) if page else ids[name]):
                errors.append(f"{name}: fragment not found: {href}")
    return errors


def main():
    check_only = "--check" in sys.argv[1:]
    unknown = [a for a in sys.argv[1:] if a not in ("--check",)]
    if unknown:
        print(f"ERROR: unknown argument: {unknown[0]}", file=sys.stderr)
        return 2

    md_files = collect_markdown_files()
    if not md_files:
        print("ERROR: no docs/*.md files found", file=sys.stderr)
        return 1

    errors = []
    for md in md_files:
        if not page_title(md.read_text(encoding="utf-8")):
            errors.append(f"{md.name}: no level-1 heading")
    check_links(md_files, errors)
    check_index_links(md_files, errors)
    check_llms(md_files, errors)

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print(f"checked {len(md_files)} page(s): links, index coverage, llms.txt OK")
    if check_only:
        return 0
    return 0 if render(md_files) else 1


if __name__ == "__main__":
    sys.exit(main())
