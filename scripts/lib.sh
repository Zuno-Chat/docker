# Shared by scripts/*.sh, sourced from the repo root. Admin calls run inside
# the synapse container: the gateway does not expose /_synapse/admin.

# json <key>: prints one top-level field of the JSON on stdin; "" if absent.
json() {
  python3 -c 'import sys, json
try:
    v = json.load(sys.stdin).get(sys.argv[1], "")
except Exception:
    v = ""
print(v if isinstance(v, str) else json.dumps(v))' "$1"
}

# admin_login: sets ADMIN_TOKEN, valid 24h (refreshable_access_token_lifetime):
# pair it with admin_logout on exit. Prompts for credentials missing from
# ADMIN_USER / ADMIN_PASSWORD. The password travels on stdin, never in a
# command line.
admin_login() {
  [ -n "${ADMIN_USER:-}" ] || read -rp "Admin username: " ADMIN_USER
  [ -n "${ADMIN_PASSWORD:-}" ] || { read -rsp "Admin password: " ADMIN_PASSWORD; echo; }
  export ADMIN_USER ADMIN_PASSWORD
  ADMIN_TOKEN=$(python3 -c 'import json, os
print(json.dumps({"type": "m.login.password", "refresh_token": True,
                  "identifier": {"type": "m.id.user", "user": os.environ["ADMIN_USER"]},
                  "password": os.environ["ADMIN_PASSWORD"]}))' |
    docker compose exec -T synapse curl -sS -X POST --data @- \
      http://localhost:8008/_matrix/client/v3/login | json access_token)
  [ -n "$ADMIN_TOKEN" ] || { echo "admin login failed" >&2; return 1; }
}

# admin_logout: revokes ADMIN_TOKEN and deletes the device admin_login created.
admin_logout() {
  if [ -n "${ADMIN_TOKEN:-}" ]; then
    admin_api POST /_matrix/client/v3/logout '{}' >/dev/null
    ADMIN_TOKEN=""
  fi
}

# admin_api <method> <path> [json-body]
admin_api() {
  local body=()
  [ -n "${3:-}" ] && body=(--data "$3")
  docker compose exec -T synapse curl -sS -X "$1" \
    -H "Authorization: Bearer $ADMIN_TOKEN" "${body[@]}" "http://localhost:8008$2"
}
