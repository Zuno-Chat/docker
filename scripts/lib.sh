# Shared by scripts/*.sh, sourced from the repo root. Every admin call runs curl
# inside the synapse container: nginx refuses /_synapse/admin, and MAS's admin
# API listens on its internal listener only (mas/config.yaml). curl reads its
# options from stdin, so no token or secret is on a command line, where ps
# shows it to every user on the host.

# json <key[.key…]>: prints one field of the JSON on stdin, following dots into
# nested objects; "" if absent.
json() {
  python3 -c 'import sys, json
try:
    v = json.load(sys.stdin)
    for k in sys.argv[1].split("."):
        v = v.get(k, "") if isinstance(v, dict) else ""
except Exception:
    v = ""
print(v if isinstance(v, str) else json.dumps(v))' "$1"
}

MAS_SCRIPTS_CLIENT=01M6KQD7M2ZZ5FC1K5DV98698S

curl_opt() {
  local v=${2//\\/\\\\}
  v=${v//\"/\\\"}
  printf '%s = "%s"\n' "$1" "${v//$'\n'/\\n}"
}

synapse_curl() {
  docker compose exec -T synapse curl -sS -K -
}

mas_client() {
  curl_opt user "$MAS_SCRIPTS_CLIENT:$(docker compose exec -T mas cat /data/scripts_client_secret)"
}

mas_admin_token() {
  MAS_ADMIN_TOKEN=$({
    mas_client
    curl_opt data "grant_type=client_credentials&scope=urn:mas:admin"
    curl_opt url http://mas:8080/oauth2/token
  } | synapse_curl | json access_token)
  [ -n "$MAS_ADMIN_TOKEN" ] || { echo "MAS admin token failed" >&2; return 1; }
}

mas_revoke_admin_token() {
  {
    mas_client
    curl_opt data "token=$MAS_ADMIN_TOKEN"
    curl_opt url http://mas:8080/oauth2/revoke
    echo fail
  } | synapse_curl >/dev/null ||
    echo "revoking the MAS admin token failed: it expires within 5 minutes" >&2
  MAS_ADMIN_TOKEN=""
}

mas_api() {
  [ -n "${MAS_ADMIN_TOKEN:-}" ] || mas_admin_token || return 1
  {
    curl_opt header "Authorization: Bearer $MAS_ADMIN_TOKEN"
    if [ "$1" = POST ]; then
      curl_opt header "Content-Type: application/json"
      curl_opt data "${3:-"{}"}"
    fi
    curl_opt url "http://mas:8081$2"
    echo fail
  } | synapse_curl
}

# admin_login: sets ADMIN_TOKEN, a Synapse admin token from a MAS personal
# session acting as ADMIN_USER (prompted if unset), valid 1 h: pair it with
# admin_logout on exit, which revokes it and the MAS admin token behind it. No
# password is involved.
admin_login() {
  [ -n "${ADMIN_USER:-}" ] || read -rp "Admin username: " ADMIN_USER
  export ADMIN_USER
  mas_admin_token || return 1
  local id session
  id=$(mas_api GET "/api/admin/v1/users/by-username/$ADMIN_USER" | json data.id)
  [ -n "$id" ] || { echo "no MAS user $ADMIN_USER" >&2; return 1; }
  session=$(mas_api POST /api/admin/v1/personal-sessions \
    "{\"actor_user_id\": \"$id\", \"human_name\": \"zuno-scripts\", \"scope\": \"urn:matrix:client:api:* urn:synapse:admin:*\", \"expires_in\": 3600}")
  ADMIN_SESSION=$(json data.id <<<"$session")
  ADMIN_TOKEN=$(json data.attributes.access_token <<<"$session")
  [ -n "$ADMIN_TOKEN" ] || { echo "admin session failed" >&2; return 1; }
}

admin_logout() {
  if [ -n "${ADMIN_SESSION:-}" ]; then
    mas_api POST "/api/admin/v1/personal-sessions/$ADMIN_SESSION/revoke" >/dev/null ||
      echo "revoking the admin session failed: it expires within the hour" >&2
    ADMIN_SESSION=""
    ADMIN_TOKEN=""
  fi
  if [ -n "${MAS_ADMIN_TOKEN:-}" ]; then
    mas_revoke_admin_token
  fi
}

# admin_api <method> <path> [json-body]
admin_api() {
  {
    curl_opt header "Authorization: Bearer $ADMIN_TOKEN"
    curl_opt request "$1"
    if [ -n "${3:-}" ]; then curl_opt data "$3"; fi
    curl_opt url "http://localhost:8008$2"
  } | synapse_curl
}
