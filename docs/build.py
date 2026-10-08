#!/usr/bin/env python3
"""Validate docs/ and render the GitHub Pages site into _site/.

Checks (always, stdlib only):
  * every relative link in every docs/*.md resolves to a file in docs/
  * every docs/*.md is linked from docs/index.md
  * every docs/*.md is listed in docs/llms.txt
  * every page has a level-1 heading (the HTML <title>)

Render (default):
  * _site/<name>.html   rendered page (links rewritten .md -> .html)
  * _site/<name>.md     raw markdown copy (machine readers fetch this)
  * _site/llms.txt      raw copy
  * then every rendered fragment link (page#id) must resolve

Usage:
  python3 docs/build.py           check + render (needs the `markdown` package)
  python3 docs/build.py --check   check only (no third-party dependency)

Install the render dependency from the committed Pipfile.lock:
  pipenv sync            (or `pipenv install --deploy` to verify the lock)
  pipenv run python3 docs/build.py
"""

import html
import re
import shutil
import sys
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


def render(md_files):
    try:
        import markdown
    except ImportError:
        print("ERROR: the 'markdown' package is required to render.", file=sys.stderr)
        print("       pipenv sync && pipenv run python3 docs/build.py", file=sys.stderr)
        print("       (or run with --check for validation only)", file=sys.stderr)
        return False

    if SITE.exists():
        shutil.rmtree(SITE)
    SITE.mkdir(parents=True)

    for md in md_files:
        text = md.read_text(encoding="utf-8")
        title = page_title(text) or md.name
        body = markdown.markdown(
            text, extensions=["extra", "toc"], output_format="html5"
        )
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
