#!/usr/bin/env bash
# End-to-end check of the running stack through its public URL.
#   scripts/smoke-test.sh public   from any machine
#   scripts/smoke-test.sh full     on the server: also creates a throwaway
#                                  user in MAS, signs it in with a password,
#                                  exercises it, then erases the user, room
#                                  and media
#   scripts/smoke-test.sh monitoring   on the server: Prometheus scrape targets,
#                                  Postgres and backup metrics, Grafana
#                                  dashboards and alert rules (README.md,
#                                  Monitoring)
# Env: BASE_URL       default https://api.zuno.chat
#      AUTH_URL       default https://auth.zuno.chat
#      PUSH_URL       default https://push.zuno.chat
#      WELLKNOWN_URL  default https://zuno.chat/.well-known/matrix/client
#      CURL_EXTRA     extra curl flags, e.g. for a local rehearsal:
#                     "-k --connect-to api.zuno.chat:443:127.0.0.1:18443
#                      --connect-to auth.zuno.chat:443:127.0.0.1:18443
#                      --connect-to push.zuno.chat:443:127.0.0.1:18443"
#      ADMIN_USER     full mode: the MAS admin account; prompted if unset
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

mode=${1:-}
case $mode in public | full | monitoring) ;; *) sed -n '2,20p' "$0"; exit 2 ;; esac
BASE_URL=${BASE_URL:-https://api.zuno.chat}
AUTH_URL=${AUTH_URL:-https://auth.zuno.chat}
PUSH_URL=${PUSH_URL:-https://push.zuno.chat}
WELLKNOWN_URL=${WELLKNOWN_URL:-https://zuno.chat/.well-known/matrix/client}
CURL_EXTRA=${CURL_EXTRA:-}

fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
expect() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected $2, got ${3:-nothing})"; fi; }
# CURL_EXTRA is split into flags on purpose.
pub() { curl -sS -m 30 $CURL_EXTRA "$@"; }
code() { pub -o /dev/null -w '%{http_code}' "$@"; }

# --- Monitoring (server only) -------------------------------------------------
if [ "$mode" = monitoring ]; then
  mon() { docker compose exec -T prometheus wget -qO- "$1"; }

  down=$(mon 'http://localhost:9090/api/v1/targets?state=active' | python3 -c 'import sys, json
print(" ".join(sorted(t["labels"].get("process") or t["labels"]["job"] for t in json.load(sys.stdin)["data"]["activeTargets"] if t["health"] != "up")))')
  expect "every scrape target up" "" "$down"

  # promq <url-encoded PromQL>: the first result's value; "" if none.
  promq() {
    mon "http://localhost:9090/api/v1/query?query=$1" | python3 -c 'import sys, json
r = json.load(sys.stdin)["data"]["result"]
print(r[0]["value"][1] if r else "")'
  }
  expect "postgres-exporter logged in to Postgres" 1 "$(promq 'max%28pg_up%29')"
  # One account count and three report counts (monitoring/postgres/queries.yaml).
  expect "postgres-exporter counts accounts and reports" 4 \
    "$(promq 'count%28%7B__name__%3D~%22zuno_accounts_registered%7Czuno_reports_filed%22%7D%29')"
  # Absent until scripts/backup.sh has finished once on this host.
  expect "node-exporter reads the backup timestamp" 1 \
    "$(promq 'count%28zuno_backup_last_success_timestamp_seconds%29')"

  # The admin password stays inside the container.
  graf() {
    docker compose exec -T grafana sh -c 'wget -qO- --header "Authorization: Basic $(printf "admin:%s" "$GF_SECURITY_ADMIN_PASSWORD" | base64)" "http://localhost:3000$1"' sh "$1" |
      python3 -c 'import sys, json; print(len(json.load(sys.stdin)))'
  }
  expect "Grafana loaded every dashboard" "$(ls monitoring/grafana/dashboards/*.json | wc -l)" \
    "$(graf '/api/search?type=dash-db&folderUIDs=zuno')"
  expect "Grafana loaded every alert rule" "$(grep -c '^      - uid:' monitoring/grafana/provisioning/alerting/rules.yaml)" \
    "$(graf /api/v1/provisioning/alert-rules)"

  echo "$fails failure(s)"
  exit $((fails > 0))
fi

# --- Public surface -----------------------------------------------------------
expect "client API reachable" 200 "$(code "$BASE_URL/_matrix/client/versions")"
case $(pub "$WELLKNOWN_URL") in
  *'"m.homeserver"'*) pass "well-known served" ;;
  *) fail "well-known served at $WELLKNOWN_URL" ;;
esac
expect "federation blocked" 403 "$(code "$BASE_URL/_matrix/federation/v1/version")"
expect "admin API not public" 403 "$(code "$BASE_URL/_synapse/admin/v1/server_version")"
expect "calls module reachable" 401 \
  "$(code -X POST "$BASE_URL/_synapse/client/zuno/calls/cloudflare/turn/credentials")"
expect "auth metadata names $AUTH_URL" "$AUTH_URL/" \
  "$(pub "$BASE_URL/_matrix/client/v1/auth_metadata" | json issuer)"
expect "sign-in page served" 200 "$(code "$AUTH_URL/login")"
theme=$(pub "$AUTH_URL/login" | grep -o 'zuno-[0-9a-f]\{12\}' | head -n 1)
expect "sign-in page wears the Zuno theme" 200 "$([ -n "$theme" ] && code "$AUTH_URL/assets/$theme/zuno.css")"
case $(pub "$BASE_URL/_matrix/client/v3/login") in
  *'"m.login.password"'*) pass "password sign-in offered to older apps" ;;
  *) fail "password sign-in offered to older apps" ;;
esac
expect "legacy registration refused" 403 "$(code -X POST "$BASE_URL/_matrix/client/v3/register" -d '{}')"
expect "MAS admin API not public" 404 "$(code "$AUTH_URL/api/admin/v1/users")"
expect "MAS metrics not public" 404 "$(code "$AUTH_URL/metrics")"
expect "MAS health not public" 404 "$(code "$AUTH_URL/health")"
# One tile, billed by MapTiler like any other.
expect "map tiles served to the app" "200 image/png" \
  "$(pub -A 'Zuno/smoke-test (im.zuno.chat)' -o /dev/null -w '%{http_code} %{content_type}' "$BASE_URL/maps/0/0/0")"
expect "map tiles refused to other clients" 403 "$(code "$BASE_URL/maps/0/0/0")"
notify='{"notification":{"devices":[{"app_id":"smoke.test","pushkey":"smoke-test"}]}}'
expect "push gateway open to every homeserver" '["smoke-test"]' \
  "$(pub -X POST "$PUSH_URL/_matrix/push/v1/notify" -d "$notify" | json rejected)"
expect "push gateway takes only POST" 403 "$(code "$PUSH_URL/_matrix/push/v1/notify")"
expect "push gateway serves nothing else" 404 "$(code "$PUSH_URL/_matrix/client/versions")"
expect "older push route open to every homeserver" '["smoke-test"]' \
  "$(pub -X POST "$BASE_URL/_matrix/push/v1/notify" -d "$notify" | json rejected)"
expect "older push route takes only POST" 403 "$(code "$BASE_URL/_matrix/push/v1/notify")"

if [ "$mode" = public ]; then
  echo "$fails failure(s)"
  exit $((fails > 0))
fi

# --- Full client flow (server only) -------------------------------------------
room="" media="" mas_uid="" blob=$(mktemp)
cleanup() {
  [ -n "$room" ] && admin_api DELETE "/_synapse/admin/v1/rooms/$room" '{"purge": true}' >/dev/null
  [ -n "$media" ] && admin_api DELETE "/_synapse/admin/v1/media/$media" >/dev/null
  [ -n "$mas_uid" ] && { mas_api POST "/api/admin/v1/users/$mas_uid/deactivate" '{}' >/dev/null ||
    echo "cleanup: deactivating $user failed: deactivate it in MAS by hand" >&2; }
  admin_logout
  rm -f "$blob"
}
trap cleanup EXIT

admin_login || exit 1
user="smoketest$(date +%s)"
pw=$(openssl rand -hex 16)
mas_uid=$(mas_api POST /api/admin/v1/users "{\"username\": \"$user\"}" | json data.id)
if [ -n "$mas_uid" ]; then pass "create user in MAS"; else fail "create user in MAS"; exit 1; fi
mas_api POST "/api/admin/v1/users/$mas_uid/set-password" \
  "{\"password\": \"$pw\", \"skip_password_check\": true}" >/dev/null

login=$(pub -X POST "$BASE_URL/_matrix/client/v3/login" -H 'Content-Type: application/json' \
  -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"$user\"},\"password\":\"$pw\",\"refresh_token\":true}")
at=$(json access_token <<<"$login")
rt=$(json refresh_token <<<"$login")
ttl=$(json expires_in_ms <<<"$login")
if [ -n "$at" ] && [ -n "$rt" ]; then pass "password sign-in through MAS"; else fail "password sign-in through MAS: $login"; exit 1; fi
if [[ $ttl =~ ^[0-9]+$ ]] && [ "$ttl" -ge 3600000 ] && [ "$ttl" -le 86400000 ]; then
  pass "access token lasts up to a day"
else
  fail "access token lasts up to a day (got ${ttl:-nothing} ms)"
fi

at=$(pub -X POST "$BASE_URL/_matrix/client/v3/refresh" -H 'Content-Type: application/json' -d "{\"refresh_token\":\"$rt\"}" | json access_token)
if [ -n "$at" ]; then pass "refresh token renews access"; else fail "refresh token renews access"; exit 1; fi

auth=(-H "Authorization: Bearer $at")
provisioned=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -n "$(pub "${auth[@]}" "$BASE_URL/_matrix/client/v3/account/whoami" | json user_id)" ] && { provisioned=1; break; }
  sleep 1
done
if [ -n "$provisioned" ]; then pass "Synapse accepts the MAS token"; else fail "Synapse accepts the MAS token"; exit 1; fi
room=$(pub "${auth[@]}" -X POST "$BASE_URL/_matrix/client/v3/createRoom" -d '{"preset":"private_chat"}' | json room_id)
expect "new rooms are encrypted" m.megolm.v1.aes-sha2 \
  "$(pub "${auth[@]}" "$BASE_URL/_matrix/client/v3/rooms/$room/state/m.room.encryption" | json algorithm)"
event=$(pub "${auth[@]}" -X PUT "$BASE_URL/_matrix/client/v3/rooms/$room/send/m.room.message/smoke1" \
  -d '{"msgtype":"m.text","body":"smoke test"}' | json event_id)
if [ -n "$event" ]; then pass "send message"; else fail "send message"; fi

head -c 1048576 /dev/urandom >"$blob"
mxc=$(pub "${auth[@]}" -X POST "$BASE_URL/_matrix/media/v3/upload?filename=smoke.bin" \
  -H 'Content-Type: application/octet-stream' --data-binary @"$blob" | json content_uri)
media=${mxc#mxc://}
expect "media upload and download (1 MiB)" 1048576 \
  "$(pub "${auth[@]}" -o /dev/null -w '%{size_download}' "$BASE_URL/_matrix/client/v1/media/download/$media")"

synced=""
for _ in 1 2 3; do
  case $(pub "${auth[@]}" "$BASE_URL/_matrix/client/v3/sync?timeout=0") in *"$event"*) synced=1; break ;; esac
  sleep 1
done
if [ -n "$synced" ]; then pass "sync returns the message"; else fail "sync returns the message"; fi

echo "$fails failure(s)"
exit $((fails > 0))
