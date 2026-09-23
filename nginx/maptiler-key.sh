#!/bin/sh
# Runs before nginx starts, like push-allow.sh (docker-compose.yml mounts it
# into /docker-entrypoint.d/). Writes MAPTILER_API_KEY (.env) as the variable
# the /maps/ route in nginx.conf appends to each MapTiler request. Only the
# master process reads config, as root, so the file is root-only. A MapTiler
# key is letters and digits: anything else stops the container rather than be
# pasted into nginx's config.
set -eu

: "${MAPTILER_API_KEY:?set in .env}"
case $MAPTILER_API_KEY in
  *[!A-Za-z0-9]*)
    echo "maptiler-key.sh: MAPTILER_API_KEY is not a MapTiler key (letters and digits only)" >&2
    exit 1
    ;;
esac

umask 077
printf 'set $maptiler_key "%s";\n' "$MAPTILER_API_KEY" > /etc/nginx/maptiler-key.conf
