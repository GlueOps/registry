#!/usr/bin/env bash
# Reproduce GlueOps/registry#8 against a built image, docker only.
#
# A throwaway network namespace holds the registry. Once an image is cached,
# every outbound TCP packet except replies on the registry's own port is dropped
# silently (as in the issue), and cached pulls are timed: before and after a
# restart, and with concurrency. A second image can be run as the control.
#
#   scripts/e2e-outage.sh IMAGE [CONTROL_IMAGE]
#
# Variables: UPSTREAM (default https://ghcr.io), IMAGE_REF (path:tag on the
# upstream, default linuxcontainers/alpine:3.20), UNCACHED_REF (a tag not pulled
# before the outage, default linuxcontainers/alpine:3.18), PORT (default 5000).
# Docker Hub as UPSTREAM works but anonymous pulls are limited to 10/h/IP.
set -euo pipefail

image=${1:?usage: $0 IMAGE [CONTROL_IMAGE]}
control=${2:-}
UPSTREAM=${UPSTREAM:-https://ghcr.io}
IMAGE_REF=${IMAGE_REF:-linuxcontainers/alpine:3.20}
UNCACHED_REF=${UNCACHED_REF:-linuxcontainers/alpine:3.18}
PORT=${PORT:-5000}

ns=e2e-outage-ns-$PORT
reg=e2e-outage-reg-$PORT
vol=e2e-outage-cache-$PORT
tmp=$(mktemp -d)
creds=$tmp/creds.sh
accept='Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'
manifest_path="/v2/${IMAGE_REF%%:*}/manifests/${IMAGE_REF##*:}"
uncached_path="/v2/${UNCACHED_REF%%:*}/manifests/${UNCACHED_REF##*:}"

cleanup_docker() {
  docker rm -f "$reg" "$ns" >/dev/null 2>&1 || true
  docker volume rm "$vol" >/dev/null 2>&1 || true
  docker rmi -f "localhost:$PORT/$IMAGE_REF" "localhost:$PORT/$UNCACHED_REF" >/dev/null 2>&1 || true
}
trap 'cleanup_docker; rm -rf "$tmp"' EXIT
cleanup_docker

log() { printf '\n== %s\n' "$*"; }
fail=0
check() { # check LABEL SECONDS MAX [MIN]
  if awk -v s="$2" -v lo="${4:-0}" -v hi="$3" 'BEGIN{exit !(lo+0 <= s+0 && s+0 <= hi+0)}'; then
    printf '   %-52s %6.2fs  (ok, <= %ss)\n' "$1" "$2" "$3"
  else
    printf '   %-52s %6.2fs  FAIL (want %s..%ss)\n' "$1" "$2" "${4:-0}" "$3"
    fail=$((fail + 1))
  fi
}
expect() { # expect LABEL GOT WANT
  if [[ $2 == "$3" ]]; then printf '   %-52s %s\n' "$1" "$2"; else printf '   %-52s %s  FAIL (want %s)\n' "$1" "$2" "$3"; fail=$((fail + 1)); fi
}

cat >"$creds" <<'EOF'
#!/bin/sh
cat >/dev/null
echo '{"ServerURL":"","Username":"","Secret":""}'
EOF
chmod 0755 "$creds"

# curl from inside the registry's namespace, so the published port is not needed.
curl_ns() { docker run --rm --net "container:$ns" curlimages/curl:8.10.1 -s -o /dev/null --max-time 200 "$@"; }
head_time() { curl_ns -I -H "$accept" -w '%{time_total}' "http://127.0.0.1:$PORT$1"; }
head_code() { curl_ns -I -H "$accept" -w '%{http_code}' "http://127.0.0.1:$PORT$1"; }
wait_ready() {
  for _ in $(seq 60); do
    if curl_ns --max-time 2 -w '%{http_code}' "http://127.0.0.1:$PORT/v2/" | grep -q 200; then return; fi
    sleep 1
  done
  echo "registry did not come up" >&2; docker logs "$reg" >&2; exit 1
}
start_registry() { # start_registry IMAGE
  docker rm -f "$reg" >/dev/null 2>&1 || true
  # docker cp, not a bind mount: the daemon may not share this filesystem.
  docker create --name "$reg" --net "container:$ns" \
    -v "$vol:/var/lib/registry" \
    -e REGISTRY_PROXY_REMOTEURL="$UPSTREAM" -e REGISTRY_PROXY_TTL=0 \
    -e REGISTRY_PROXY_EXEC_COMMAND=/etc/distribution/creds.sh \
    -e REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY=/var/lib/registry \
    -e REGISTRY_HTTP_ADDR="0.0.0.0:$PORT" -e REGISTRY_LOG_LEVEL=info \
    "$1" >/dev/null
  docker cp "$creds" "$reg:/etc/distribution/creds.sh"
  docker start "$reg" >/dev/null
  wait_ready
}
# Stateless on purpose: conntrack has no state for connections that predate the
# rule and can take the registry's side of one for the reply direction.
rule=(OUTPUT ! -o lo -p tcp ! --sport "$PORT" -j DROP)
blackhole() {
  docker exec "$ns" iptables -I "${rule[@]}"
  local rc=0
  curl_ns --max-time 3 "$UPSTREAM/v2/" 2>/dev/null || rc=$?
  if [[ $rc -ne 28 ]]; then echo "blackhole ineffective: curl to $UPSTREAM exited $rc, want a timeout (28)" >&2; exit 1; fi
}
unblackhole() { docker exec "$ns" iptables -D "${rule[@]}"; }
pull() { docker rmi -f "localhost:$PORT/$1" >/dev/null 2>&1 || true; docker pull -q "localhost:$PORT/$1" >/dev/null; }
since() { awk -v s="$1" -v e="$(date +%s.%N)" 'BEGIN{printf "%.2f", e-s}'; }
check_pull() { # check_pull LABEL REF MAX
  local s; s=$(date +%s.%N)
  if pull "$2"; then check "$1" "$(since "$s")" "$3"; else printf '   %-52s FAIL\n' "$1"; fail=$((fail + 1)); fi
}

run_scenario() { # run_scenario LABEL IMAGE
  log "$1: $2"
  start_registry "$2"
  docker exec "$ns" sh -c 'iptables -F OUTPUT'
  pull "$IMAGE_REF"
  echo "   cache warm; upstream reachable: HEAD $(head_time "$manifest_path")s"

  blackhole
  # Lower bounds: the registry must really have waited on the upstream.
  check "HEAD, upstream blackholed (challenge known)" "$(head_time "$manifest_path")" 12 1
  check "HEAD again (failure remembered)" "$(head_time "$manifest_path")" 1
  check_pull "docker pull, cached image" "$IMAGE_REF" 15

  docker restart "$reg" >/dev/null; wait_ready
  check "HEAD after restart during the outage" "$(head_time "$manifest_path")" 12 1
  docker restart "$reg" >/dev/null; wait_ready
  start=$(date +%s.%N)
  for _ in 1 2 3 4 5; do head_time "$manifest_path" >/dev/null & done; wait
  check "5 concurrent HEADs after restart" "$(since "$start")" 12
  check_pull "docker pull after restart" "$IMAGE_REF" 15
  # A miss must still ask the upstream (and so wait for it), never be an instant 404.
  expect "uncached tag during the outage: HTTP" "$(head_code "$uncached_path")" 404
  check "uncached tag during the outage, asked upstream" "$(head_time "$uncached_path")" 60 1

  # Once the 30s memory expires, one request re-checks the upstream; the rest
  # must keep coming from the cache instead of all waiting on it.
  sleep 31
  slow=0
  for i in 1 2 3 4 5; do head_time "$manifest_path" > "$tmp/head.$i" & done; wait
  for i in 1 2 3 4 5; do awk -v s="$(cat "$tmp/head.$i")" 'BEGIN{exit !(s+0 >= 1)}' && slow=$((slow + 1)); done
  expect "5 concurrent HEADs after the memory expired: waited on upstream" "$slow" 1

  unblackhole
  check_pull "docker pull, uncached, after recovery" "$UNCACHED_REF" 60
  expect "recovery logged" "$(docker logs "$reg" 2>&1 | grep -c 'reachable again')" 1
}

docker volume create "$vol" >/dev/null
docker run -d --name "$ns" --cap-add NET_ADMIN -p "127.0.0.1:$PORT:$PORT" alpine:3.20 sleep infinity >/dev/null
docker exec "$ns" apk add -q iptables

run_scenario "fix" "$image"
if [[ -n $control ]]; then
  docker rm -f "$reg" >/dev/null
  docker volume rm "$vol" >/dev/null && docker volume create "$vol" >/dev/null
  fail_fix=$fail; fail=0
  run_scenario "control" "$control" || true
  echo; echo "control violated $fail bound(s), as expected without the fix"
  fail=$fail_fix
fi

echo
if [[ $fail -ne 0 ]]; then echo "FAILED: $image violated a bound"; exit 1; fi
echo "OK: $image"
