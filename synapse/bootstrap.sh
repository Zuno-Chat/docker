#!/bin/sh
# synapse-init (docker-compose.yml): creates the secret files homeserver.yaml
# points at and the signing key, then hands /data to Synapse's user (991).
# Idempotent: existing files are never touched. Back these up with the
# database: losing the signing key or secrets breaks every session.
set -eu

# Every Synapse process also loads /data/sentry.yaml. Synapse refuses a sentry
# section without a dsn, so an unset SYNAPSE_SENTRY_DSN writes an empty map.
# Rewritten on every start: .env is the source of truth.
if [ -n "${SYNAPSE_SENTRY_DSN:-}" ]; then
  printf 'sentry:\n  dsn: "%s"\n  environment: production\n' "$SYNAPSE_SENTRY_DSN" > /data/sentry.yaml
else
  echo '{}' > /data/sentry.yaml
fi
chmod 644 /data/sentry.yaml

mkdir -p /data/secrets /data/media
for name in macaroon_secret_key form_secret registration_shared_secret worker_replication_secret; do
  f="/data/secrets/$name"
  # No trailing newline: Synapse reads these files verbatim.
  [ -s "$f" ] || head -c 32 /dev/urandom | base64 | tr -d '\n' > "$f"
done
chmod 700 /data/secrets
chmod 600 /data/secrets/*
chown 991:991 /data /data/media /data/secrets /data/secrets/*

exec gosu 991:991 python -m synapse.app.homeserver \
  --config-path /config/homeserver.yaml --generate-keys
