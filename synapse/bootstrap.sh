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

# The zuno_calls block in homeserver.yaml reads these two. Rewritten on every
# start: .env is the source of truth. Unset stops here, before Synapse starts.
printf '%s' "${CF_CALLS_APP_SECRET:?set in .env}" > /data/secrets/cf_calls_app_secret
printf '%s' "${CF_TURN_API_TOKEN:?set in .env}" > /data/secrets/cf_turn_api_token

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
