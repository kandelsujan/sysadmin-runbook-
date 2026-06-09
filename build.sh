#!/usr/bin/env bash
#
# Build a static HTML site from EVERY .md in a directory tree, using pandoc.
#
# Alma 9 deps:
#   sudo dnf install epel-release -y
#   sudo dnf install pandoc python3 -y
#
# Usage:
#   ./build.sh                  # source = current dir, output = ./_site
#   ./build.sh ./docs ./_site   # explicit source and output dirs
#   PORT=9000 ./build.sh        # override the serve port (default 8000)
#
set -euo pipefail

SRC="$(cd "${1:-.}" && pwd)"
OUT="${2:-_site}"
PORT="${PORT:-8000}"

rm -rf "$OUT"
mkdir -p "$OUT"

# --- link rewriter: turn  foo.md  and  foo.md#sec  into  foo.html / foo.html#sec
LUA="$(mktemp)"
cat > "$LUA" <<'LUA'
function Link(el)
  el.target = el.target:gsub('%.md(#?)', '.html%1')
  return el
end
LUA

# --- shared stylesheet (GitHub-ish), served at the site root as /style.css
cat > "$OUT/style.css" <<'CSS'
:root{color-scheme:dark}
html,body{background:#0d1117}
body{max-width:860px;margin:0 auto;padding:32px 24px 80px;
     color:#e6edf3;font:16px/1.6 -apple-system,Segoe UI,Helvetica,Arial,sans-serif}
a{color:#4493f8;text-decoration:none} a:hover{text-decoration:underline}
h1,h2,h3{border-bottom:1px solid #30363d;padding-bottom:.3em;margin-top:1.6em}
code{background:rgba(110,118,129,.4);padding:.15em .35em;border-radius:4px;
     font:.9em ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
pre{background:#161b22;padding:14px 16px;border-radius:8px;overflow:auto;
    border:1px solid #30363d}
pre code{background:none;padding:0}
table{border-collapse:collapse;margin:1em 0}
th,td{border:1px solid #30363d;padding:6px 12px} th{background:#161b22}
blockquote{margin:0;padding:0 1em;color:#8b949e;border-left:.25em solid #30363d}
img{max-width:100%}
.files{list-style:none;padding:0} .files li{margin:.3em 0}
.home{display:inline-block;margin-bottom:1em}
CSS

# --- convert every .md, preserving the folder structure, collecting an index list
LIST="$(mktemp)"
: > "$LIST"
while IFS= read -r -d '' f; do
  rel="${f#"$SRC"/}"
  dest="$OUT/${rel%.md}.html"
  mkdir -p "$(dirname "$dest")"
  pandoc "$f" -s \
    --lua-filter="$LUA" \
    --metadata title="$(basename "${rel%.md}")" \
    -c /style.css \
    -B <(printf '<a class="home" href="/">&#8592; index</a>') \
    -o "$dest"
  printf '<li><a href="/%s">%s</a></li>\n' "${rel%.md}.html" "$rel" >> "$LIST"
done < <(find "$SRC" -name '*.md' -not -path "$OUT/*" -print0 | sort -z)

# --- landing page that links to everything
{
  echo '<!doctype html><html><head><meta charset="utf-8">'
  echo '<meta name="viewport" content="width=device-width,initial-scale=1">'
  echo '<title>Cheatsheet</title><link rel="stylesheet" href="/style.css"></head>'
  echo '<body><h1>Cheatsheet</h1><ul class="files">'
  cat "$LIST"
  echo '</ul></body></html>'
} > "$OUT/index.html"

rm -f "$LIST" "$LUA"

echo "Built static site -> $OUT/"
echo "Serving at http://localhost:$PORT   (Ctrl+C to stop)"
cd "$OUT" && python3 -m http.server "$PORT"
