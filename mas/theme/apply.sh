set -eu
up=$1
theme=$2
out=$3
name=Zuno
work=$out.partial
set -- zuno.css logo-light.svg logo-dark.svg icon.svg

die() { echo "apply.sh: $*" >&2; exit 1; }

[ ! -e "$out" ] || die "$out already exists"
trap 'rm -rf "$work"' EXIT
rm -rf "$work"
mkdir -p "$work/templates" "$work/translations"

for f in "$@"; do
  [ -s "$theme/$f" ] || die "theme file $f is missing"
done

missing=$(grep -o -- '--cpd-[a-z0-9-]*:' "$theme/zuno.css" | sort -u | while read -r token; do
  grep -q -- "$token" "$up"/assets/*.css || printf '%s ' "${token%:}"
done)
[ -z "$missing" ] || die "zuno.css sets tokens this MAS's CSS doesn't define: $missing"

hash=$(cd "$theme" && cat "$@" | sha256sum | cut -c1-12)
assets=zuno-$hash
mkdir -p "$work/assets/$assets"
for f in "$@"; do
  cp "$theme/$f" "$work/assets/$assets/"
done

url() { printf "{{ '/assets/%s/%s' | prefix_url }}" "$assets" "$1"; }

head_links="    <link rel=\"icon\" type=\"image/svg+xml\" href=\"$(url icon.svg)\">
    <link rel=\"stylesheet\" href=\"$(url zuno.css)\">"

logo="      <picture class=\"zuno-logo\">
        <source media=\"(prefers-color-scheme: dark)\" srcset=\"$(url logo-dark.svg)\">
        <img src=\"$(url logo-light.svg)\" alt=\"{{ _('app.name') }}\" width=\"119\" height=\"40\">
      </picture>"

inject() {
  file=$work/templates/$1
  n=$(grep -c -- "$2" "$file" || true)
  [ "$n" = 1 ] || die "$1: expected one line matching '$2', found $n"
  SNIPPET=$4 awk -v a="$2" -v w="$3" '
    w == "before" && $0 ~ a { print ENVIRON["SNIPPET"] }
    { print }
    w == "after" && $0 ~ a { print ENVIRON["SNIPPET"] }
  ' "$file" >"$file.tmp"
  mv "$file.tmp" "$file"
}

cp "$up/templates/base.html" "$up/templates/app.html" "$work/templates/"
inject base.html '^ *</head>$' before "$head_links"
inject base.html '<div class="layout-container' after "$logo"
inject app.html '^ *</head>$' before "$head_links"

for f in "$up"/translations/*.json; do
  jq --arg n "$name" '.app.name = $n | .app.human_name = $n' "$f" >"$work/translations/${f##*/}"
done

mv "$work" "$out"
