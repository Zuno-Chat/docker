set -eu
data=$1
umask 077
nl=$(printf '\nx')
nl=${nl%x}

check() {
  case $2 in
    *'"'* | *\\* | *"$nl"*) echo "$1 holds a quote, backslash or newline: generate another" >&2; exit 1 ;;
  esac
}
check SYNAPSE_SHARED_SECRET "${SYNAPSE_SHARED_SECRET:-}"
check DB_PASSWORD "${DB_PASSWORD:-}"
check SMTP_USERNAME "${SMTP_USERNAME:-}"
check SMTP_PASSWORD "${SMTP_PASSWORD:-}"
check TURNSTILE_SITE_KEY "${TURNSTILE_SITE_KEY:-}"
check TURNSTILE_SECRET "${TURNSTILE_SECRET:-}"

if [ ! -s "$data/keys.yaml" ]; then
  mas-cli config generate --output "$data/generated.yaml.tmp"
  awk '/^secrets:/ { p = 1; print; next } p && /^[^ ]/ { exit } p' "$data/generated.yaml.tmp" >"$data/keys.yaml.tmp"
  rm "$data/generated.yaml.tmp"
  grep -q '^  encryption: ' "$data/keys.yaml.tmp" || { echo "mas-cli config generate gave no secrets block" >&2; exit 1; }
  mv "$data/keys.yaml.tmp" "$data/keys.yaml"
fi

random_once() {
  [ -s "$data/$1" ] && return 0
  head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n' >"$data/$1.tmp"
  mv "$data/$1.tmp" "$data/$1"
}
random_once scripts_client_secret
random_once password_pepper

cat >"$data/env.yaml.tmp" <<EOF
matrix:
  secret: "$SYNAPSE_SHARED_SECRET"
database:
  password: "$DB_PASSWORD"
email:
  username: "$SMTP_USERNAME"
  password: "$SMTP_PASSWORD"
captcha:
  site_key: "$TURNSTILE_SITE_KEY"
  secret_key: "$TURNSTILE_SECRET"
EOF
mv "$data/env.yaml.tmp" "$data/env.yaml"

chmod 700 "$data"
chown -R 65532:65532 "$data"
