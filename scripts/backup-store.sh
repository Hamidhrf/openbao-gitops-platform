#!/usr/bin/env bash
# Starts the host backup store for PostgreSQL backups (ADR-005):
# Versity S3 Gateway in Docker, outside kind, reachable only on the kind
# network gateway over HTTPS. Safe to run again. Never prints secrets.
set -euo pipefail
export PATH=/usr/bin:/bin   # system tools only, whatever the calling shell has on PATH
umask 077

IMAGE=ghcr.io/versity/versitygw@sha256:30292fc2eeacc67a36993b01f7a7a5e3361a19cced0e80c1d71cfa2a4b0a2499 # v1.8.0
NAME=backup-store
GATEWAY=172.18.0.1   # IPv4 gateway of the kind Docker network
PORT=9000
BUCKET=pg-backups
CERT_DAYS=365

REPO=$(cd "$(dirname "$0")/.." && pwd)
SOPS=$REPO/.bin/sops
CRED=$REPO/scripts/backup-store.sops.env
URL=https://$GATEWAY:$PORT

die() { echo "backup-store: $*" >&2; exit 1; }
say() { echo "backup-store: $*"; }

# Recorded as a container label, so a later run can tell whether the running
# container was created with the current settings.
config_label() { echo "$IMAGE $GATEWAY:$PORT $1"; }

main() {
  STATE_DIR=${BACKUP_STORE_DIR:-$HOME/backup-store}
  TLS=$STATE_DIR/tls
  # These paths are quoted into the command for sops exec-env below.
  local p
  for p in "$HOME" "$STATE_DIR" "$REPO"; do
    case $p in *[!A-Za-z0-9/._-]*) die "path $p may only contain letters, digits and / . _ -" ;; esac
  done
  [ -x "$SOPS" ] || die "missing $SOPS (run scripts/install-tools.sh)"
  [ -f "$CRED" ] || die "missing $CRED (create the credential first, see README)"

  # Disk rule: warn below 45 GB free, stop below 40 GB.
  local free_gb
  free_gb=$(df --output=avail -BG / | tail -n 1 | tr -dc '0-9')
  [ "$free_gb" -ge 40 ] || die "only ${free_gb} GB free on /"
  [ "$free_gb" -ge 45 ] || say "warning: only ${free_gb} GB free on /"

  local gateways
  gateways=$(docker network inspect kind --format '{{range .IPAM.Config}}{{.Gateway}} {{end}}') \
    || die "no kind Docker network"
  case " $gateways " in
    *" $GATEWAY "*) ;;
    *) die "kind network gateway is not $GATEWAY (found: $gateways)" ;;
  esac

  local status
  status=$(docker container inspect --format '{{.State.Status}}' "$NAME" 2>/dev/null || true)
  if [ -z "$status" ]; then
    # First start: port, directories, certificate, image.
    [ -z "$(ss -ltnH "( sport = :$PORT )")" ] || die "port $PORT is already in use"
    mkdir -p "$STATE_DIR/objects" "$TLS"
    if [ ! -e "$TLS/server.crt" ] && [ ! -e "$TLS/server.key" ]; then
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
        -keyout "$TLS/server.key" -out "$TLS/server.crt" -days "$CERT_DAYS" \
        -subj "/CN=backup-store" \
        -addext "subjectAltName=IP:$GATEWAY" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,digitalSignature,keyCertSign" \
        -addext "extendedKeyUsage=serverAuth"
      say "created a new certificate; the endpointCA Secret must use it"
    fi
    docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull "$IMAGE"
  else
    [ "$(docker container inspect --format '{{index .Config.Labels "backup-store.config"}}' "$NAME")" = "$(config_label "$STATE_DIR")" ] \
      || die "container $NAME was created with other settings; remove it (docker rm -f $NAME, data stays in $STATE_DIR) and run again"
    [ "$status" = running ] \
      || die "container $NAME is $status; start it with: docker start $NAME"
  fi

  # Never regenerate half of the TLS identity, and never serve an expired certificate.
  [ -e "$TLS/server.crt" ] && [ -e "$TLS/server.key" ] \
    || die "$TLS must contain both server.crt and server.key"
  openssl x509 -checkend 0 -noout -in "$TLS/server.crt" >/dev/null \
    || die "certificate $TLS/server.crt has expired"
  openssl x509 -checkend $((30 * 86400)) -noout -in "$TLS/server.crt" >/dev/null \
    || say "warning: certificate expires within 30 days"

  # Decrypt the credential only for the part that needs it. --pristine gives
  # the inner run only the decrypted variables, so HOME is passed explicitly.
  "$SOPS" exec-env --pristine "$CRED" \
    "HOME='$HOME' exec /bin/bash '$REPO/scripts/backup-store.sh' inner '$STATE_DIR'"

  say "running at $URL"
  say "CA certificate $TLS/server.crt"
  openssl x509 -noout -enddate -fingerprint -sha256 -in "$TLS/server.crt"
}

# Runs inside sops exec-env: ROOT_ACCESS_KEY_ID and ROOT_SECRET_ACCESS_KEY are set.
inner() {
  STATE_DIR=$1
  TLS=$STATE_DIR/tls
  : "${ROOT_ACCESS_KEY_ID:?missing}" "${ROOT_SECRET_ACCESS_KEY:?missing}"

  if ! docker container inspect "$NAME" >/dev/null 2>&1; then
    # -e NAME without a value: Docker copies the value from this process's
    # environment, so it never appears on a command line.
    # No --log-level flag: the default is silent (level "unsafe" prints secrets).
    docker run -d --name "$NAME" \
      --restart unless-stopped \
      --label "backup-store.config=$(config_label "$STATE_DIR")" \
      --user "$(id -u):$(id -g)" \
      --cap-drop ALL --security-opt no-new-privileges:true \
      --read-only --tmpfs /tmp \
      -p "$GATEWAY:$PORT:7070" \
      -e ROOT_ACCESS_KEY_ID -e ROOT_SECRET_ACCESS_KEY \
      -v "$STATE_DIR/objects:/data" -v "$TLS:/tls:ro" \
      "$IMAGE" \
      --cert /tls/server.crt --key /tls/server.key --health /health \
      posix /data >/dev/null
    say "started container $NAME"
  fi

  local code=""
  for _ in $(seq 1 30); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$TLS/server.crt" "$URL/health" || true)
    [ "$code" = 200 ] && break
    sleep 1
  done
  [ "$code" = 200 ] || die "no healthy answer from $URL/health (see: docker logs $NAME)"

  code=$(s3_status --head)
  case $code in
    200) say "bucket $BUCKET exists" ;;
    404)
      code=$(s3_status -X PUT)
      [ "$code" = 200 ] || die "creating bucket $BUCKET failed (HTTP $code)"
      say "created bucket $BUCKET" ;;
    *) die "unexpected HTTP $code for bucket $BUCKET (check the credential)" ;;
  esac
}

# Signed S3 request to the bucket. The credential goes to curl on stdin,
# never on the command line. Prints only the HTTP status code.
s3_status() {
  printf 'user = "%s:%s"\n' "$ROOT_ACCESS_KEY_ID" "$ROOT_SECRET_ACCESS_KEY" \
    | curl -s -o /dev/null -w '%{http_code}' -K - --aws-sigv4 "aws:amz:us-east-1:s3" \
        --cacert "$TLS/server.crt" "$@" "$URL/$BUCKET" || true
}

case "${1:-}" in
  "") main ;;
  inner) inner "${2:?}" ;;
  *) die "usage: scripts/backup-store.sh" ;;
esac
