#!/bin/sh
set -eu

MOUNT=secret
CONSUMER_NAMESPACE=demo
JWT_FILE=/var/run/secrets/openbao/token

log() {
    echo "$(date -u +%FT%TZ) $*"
}

log "waiting for $BAO_ADDR"
attempt=0
until bao status >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 60 ]; then
        log "OpenBao did not become available, giving up"
        exit 1
    fi
    sleep 5
done
log "OpenBao is reachable and unsealed"

BAO_TOKEN=$(bao write -field=token auth/kubernetes/login role=admin jwt="$(cat "$JWT_FILE")")
export BAO_TOKEN
log "logged in through Kubernetes auth as openbao-admin"

if bao read "sys/mounts/$MOUNT" >/dev/null 2>&1; then
    log "mount $MOUNT/ already exists"
else
    bao secrets enable -path="$MOUNT" -version=2 kv
    log "mount $MOUNT/ enabled"
fi
log "mount $MOUNT/ options: $(bao read -field=options "sys/mounts/$MOUNT")"

ACCESSOR=$(bao read -field=accessor sys/auth/kubernetes)
log "kubernetes auth accessor: $ACCESSOR"

CALLER="{{identity.entity.aliases.$ACCESSOR.metadata.service_account_namespace}}"

bao policy write eso-pull - <<EOT
path "$MOUNT/data/apps/$CALLER/*" {
  capabilities = ["read"]
}

path "$MOUNT/metadata/apps/$CALLER/*" {
  capabilities = ["read", "list"]
}
EOT
log "policy eso-pull written"

bao policy write eso-push - <<EOT
path "$MOUNT/data/pushed/$CALLER/*" {
  capabilities = ["create", "read", "update", "delete"]
}

path "$MOUNT/metadata/pushed/$CALLER/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
EOT
log "policy eso-push written"

bao write auth/kubernetes/role/eso-pull \
    bound_service_account_names=eso-pull \
    bound_service_account_namespaces="$CONSUMER_NAMESPACE" \
    audience=openbao \
    token_policies=eso-pull \
    token_no_default_policy=true \
    token_ttl=20m \
    token_max_ttl=1h

bao write auth/kubernetes/role/eso-push \
    bound_service_account_names=eso-push \
    bound_service_account_namespaces="$CONSUMER_NAMESPACE" \
    audience=openbao \
    token_policies=eso-push \
    token_no_default_policy=true \
    token_ttl=20m \
    token_max_ttl=1h

log "state after this run"
bao secrets list
bao policy list
bao list auth/kubernetes/role

bao token revoke -self >/dev/null
log "configuration complete, token revoked"
