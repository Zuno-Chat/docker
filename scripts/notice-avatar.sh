#!/usr/bin/env bash
# Uploads the image for the server notices avatars and prints its mxc:// URI,
# the value of system_mxid_avatar_url and room_avatar_url under server_notices
# in synapse/homeserver.yaml. Run on the server.
#   scripts/notice-avatar.sh <image>     PNG, JPEG, WebP or GIF, 2 MB at most
set -euo pipefail
image=$(realpath "${1:?usage: scripts/notice-avatar.sh <image>}")
cd "$(dirname "$0")/.."
. scripts/lib.sh

# Synapse refuses to send a notice whose avatar is outside
# allowed_avatar_mimetypes or over max_avatar_size (homeserver.yaml).
case "${image,,}" in
  *.png) type=image/png ;;
  *.jpg | *.jpeg) type=image/jpeg ;;
  *.webp) type=image/webp ;;
  *.gif) type=image/gif ;;
  *) echo "not a PNG, JPEG, WebP or GIF: $image" >&2; exit 1 ;;
esac
[ "$(stat -c %s "$image")" -le $((2 * 1024 * 1024)) ] || { echo "over 2 MB: $image" >&2; exit 1; }

trap admin_logout EXIT
admin_login
uri=$(docker compose exec -T synapse curl -sS -X POST \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: $type" --data-binary @- \
  http://localhost:8008/_matrix/media/v3/upload <"$image" | json content_uri)
[ -n "$uri" ] || { echo "upload failed" >&2; exit 1; }
# media_retention skips protected media. Without this it would delete the image
# if no notice used it within local_media_lifetime of the upload.
[ "$(admin_api POST "/_synapse/admin/v1/media/protect/${uri##*/}")" = "{}" ] ||
  { echo "uploaded $uri, but protecting it failed" >&2; exit 1; }
echo "$uri"
