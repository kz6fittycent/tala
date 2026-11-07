#!/bin/bash
# Starts a throwaway Nextcloud with Talk and no High Performance Backend on
# 127.0.0.1:8088, with users alice, bob and carol (password mesh-test-<name>-pass),
# plus a container that drives Talk's web client with a fake camera. Prints a
# room token. The passwords are for this local container only.
set -eu
docker rm -f tala-mesh-nc tala-mesh-web >/dev/null 2>&1 || true
docker run -d --name tala-mesh-nc -p 127.0.0.1:8088:80 \
  -e SQLITE_DATABASE=nc -e NEXTCLOUD_ADMIN_USER=admin \
  -e NEXTCLOUD_ADMIN_PASSWORD=mesh-test-admin-only \
  -e NEXTCLOUD_TRUSTED_DOMAINS="localhost 127.0.0.1" nextcloud:34 >/dev/null
occ() { docker exec -u www-data tala-mesh-nc php occ "$@"; }
until occ status 2>/dev/null | grep -q 'installed: true'; do sleep 3; done
occ app:install spreed >/dev/null
occ app:disable firstrunwizard >/dev/null || true
for u in alice bob carol; do
  docker exec -e OC_PASS="mesh-test-$u-pass" -u www-data tala-mesh-nc \
    php occ user:add --password-from-env "$u" >/dev/null
done
docker run -d --name tala-mesh-web --network host \
  mcr.microsoft.com/playwright:v1.56.0-noble sleep 86400 >/dev/null
docker exec tala-mesh-web sh -c \
  'mkdir -p /w && cd /w && npm init -y >/dev/null && npm i playwright@1.56.0 >/dev/null 2>&1'
# Piped, because the Docker snap can't read files under /tmp.
docker exec -i tala-mesh-web sh -c 'cat > /w/web-client.js' \
  < "$(dirname "$0")/web-client.js"
api=http://127.0.0.1:8088/ocs/v2.php/apps/spreed/api/v4/room
post() {
  curl -s -u alice:mesh-test-alice-pass -H 'OCS-APIRequest: true' \
    -H 'Accept: application/json' -H 'Content-Type: application/json' -d "$2" "$1"
}
token=$(post "$api" '{"roomType":2,"roomName":"mesh"}' |
  python3 -I -c 'import json,sys;print(json.load(sys.stdin)["ocs"]["data"]["token"])')
for u in bob carol; do
  post "$api/$token/participants" "{\"newParticipant\":\"$u\",\"source\":\"users\"}" >/dev/null
done
echo "$token"
