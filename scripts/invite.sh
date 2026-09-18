#!/usr/bin/env bash
# Prints a new registration (invite) token. Run on the server.
#   scripts/invite.sh [uses] [valid-days]     defaults: 1 use, 7 days
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

uses=${1:-1}
days=${2:-7}
trap admin_logout EXIT
admin_login
expiry_ms=$(( ($(date +%s) + days * 86400) * 1000 ))
token=$(admin_api POST /_synapse/admin/v1/registration_tokens/new \
  "{\"uses_allowed\": $uses, \"expiry_time\": $expiry_ms}" | json token)
[ -n "$token" ] || { echo "token creation failed" >&2; exit 1; }
echo "$token"
