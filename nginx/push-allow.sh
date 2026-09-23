#!/bin/sh
# Runs before nginx starts: the image runs every /docker-entrypoint.d/*.sh,
# and docker-compose.yml mounts this there. Writes PUSHER_ALLOWED_CIDRS
# (.env, comma-separated) as the allow list nginx.conf includes on the push
# route. Anything but an address or CIDR stops the container instead of
# starting it with a list that means something else ("all").
set -eu

: "${PUSHER_ALLOWED_CIDRS:?set in .env}"
out=/etc/nginx/push-allow.conf
rules=""
for cidr in $(printf '%s' "$PUSHER_ALLOWED_CIDRS" | tr ',' ' '); do
  case $cidr in
    *[!0-9a-fA-F:./]*)
      echo "push-allow.sh: not an address or CIDR: $cidr" >&2
      exit 1
      ;;
  esac
  rules="${rules}allow $cidr;
"
done
[ -n "$rules" ] || { echo "push-allow.sh: PUSHER_ALLOWED_CIDRS is empty" >&2; exit 1; }
printf '%sdeny all;\n' "$rules" > "$out"
