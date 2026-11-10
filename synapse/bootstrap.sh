#!/bin/sh
# synapse-init (docker-compose.yml): creates the secret files homeserver.yaml
# points at and the signing key, then hands /data to Synapse's user (991).
# Idempotent: existing files are never touched. Back these up with the
# database: losing the signing key or secrets breaks every session.
set -eu

mkdir -p /data/secrets /data/media

# The zuno_calls and matrix_authentication_service blocks in homeserver.yaml
# read these. Rewritten on every start: .env is the source of truth. Unset
# stops here, before Synapse starts.
printf '%s' "${CF_CALLS_APP_SECRET:?set in .env}" > /data/secrets/cf_calls_app_secret
printf '%s' "${CF_TURN_API_TOKEN:?set in .env}" > /data/secrets/cf_turn_api_token
printf '%s' "${MAS_SHARED_SECRET:?set in .env}" > /data/secrets/mas_shared_secret

for name in macaroon_secret_key form_secret worker_replication_secret; do
  f="/data/secrets/$name"
  # No trailing newline: Synapse reads these files verbatim.
  [ -s "$f" ] || head -c 32 /dev/urandom | base64 | tr -d '\n' > "$f"
done
chmod 700 /data/secrets
chmod 600 /data/secrets/*
chown 991:991 /data /data/media /data/secrets /data/secrets/*

exec gosu 991:991 python -m synapse.app.homeserver \
  --config-path /config/homeserver.yaml --generate-keys
