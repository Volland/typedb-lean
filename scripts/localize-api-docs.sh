#!/usr/bin/env bash
# Makes the doc-gen4 API reference self-contained before docs.yaml publishes it under api/,
# so that no page of the site sends visitor data to a CDN (see site/datenschutz.html).
#
#   scripts/localize-api-docs.sh <api-dir>
#
# - drops the ES6 polyfill script, which every supported browser no longer needs;
# - serves MathJax from <api-dir>/vendor/mathjax instead of jsDelivr;
# - replaces the Lato and JuliaMono imports from cdnjs with the site's own fonts
#   (site/assets/fonts, published next to api/).
set -euo pipefail

api=${1:?usage: scripts/localize-api-docs.sh <api-dir>}
mathjax_version=3.2.2

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -sSfL "https://registry.npmjs.org/mathjax/-/mathjax-$mathjax_version.tgz" | tar -xz -C "$tmp"
rm -rf "$api/vendor/mathjax"
mkdir -p "$api/vendor"
cp -R "$tmp/package/es5" "$api/vendor/mathjax"

# Each page links its stylesheet relative to the API root; MathJax is loaded relative to the same root.
find "$api" -name '*.html' -print0 | xargs -0 perl -pi -e '
  my ($root) = m{<link rel="stylesheet" href="([^"]*)style\.css">};
  s{<script defer="true" src="https://cdnjs\.cloudflare\.com/polyfill/[^"]*"></script>}{}g;
  s{https://cdn\.jsdelivr\.net/npm/mathjax\@3/es5/tex-mml-chtml\.js}{${root}vendor/mathjax/tex-mml-chtml.js}g;'

perl -ni -e 'print unless m{^\@import url\(.https://cdnjs\.cloudflare\.com/}' "$api/style.css"
{
  cat <<'CSS'
/* Fonts served by this site instead of cdnjs (scripts/localize-api-docs.sh). */
@font-face { font-family: 'Lato Medium'; font-weight: 500; font-display: swap;
  src: url('../assets/fonts/inter-latin-wght-normal.woff2') format('woff2-variations'); }
@font-face { font-family: 'JuliaMono'; font-weight: 400; font-display: swap;
  src: url('../assets/fonts/jetbrains-mono-latin-wght-normal.woff2') format('woff2-variations'); }
CSS
  cat "$api/style.css"
} > "$tmp/style.css"
mv "$tmp/style.css" "$api/style.css"

if grep -rlE 'cdnjs\.cloudflare\.com|cdn\.jsdelivr\.net|fonts\.googleapis\.com' "$api" --include='*.html' --include='*.css' | grep -v '/vendor/' | head -1 | grep -q .; then
  echo "localize-api-docs: a CDN reference is left in $api" >&2
  exit 1
fi
echo "localize-api-docs: $api is self-contained"
