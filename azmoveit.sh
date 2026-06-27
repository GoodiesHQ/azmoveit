#!/usr/bin/env bash
set -Eeuo pipefail

# *** Required ***
SRC_RG="${SRC_RG:?SRC_RG is required}"
DST_RG="${DST_RG:?DST_RG is required}"
SRC_ACCOUNT="${SRC_ACCOUNT:?SRC_ACCOUNT is required}"
SRC_SHARE="${SRC_SHARE:?SRC_SHARE is required}"
DST_ACCOUNT="${DST_ACCOUNT:?DST_ACCOUNT is required}"
DST_SHARE="${DST_SHARE:?DST_SHARE is required}"
SRC_TYPE="${SRC_TYPE:?SRC_TYPE is required as \'file\' or \'blob\'}"
DST_TYPE="${DST_TYPE:?DST_TYPE is required as \'file\' or \'blob\'}"

# Optional
# SRC_TYPE / DST_TYPE: 'file' (Azure File Share) or 'blob' (Blob Storage)

# SRC_PATH / DST_PATH: path inside the share/container (default: root)
SRC_PATH="${SRC_PATH:-}"
DST_PATH="${DST_PATH:-}"
# SHARE_QUOTA_GB: quota for the destination file share in GiB (ignored for blob containers)
# 10 TiB = 10240 GiB; account must have large file shares enabled for values above 5120
SHARE_QUOTA_GB="${SHARE_QUOTA_GB:-10240}"
# SAS_HOURS: how long the generated SAS tokens stay valid — must exceed copy duration
SAS_HOURS="${SAS_HOURS:-72}"
VERIFY="${VERIFY:-true}"
# PRESERVE_PERMISSIONS: copy SMB ACLs — file-to-file only, requires premium shares and OAuth
# azcopy auth; SAS alone is not sufficient when this is enabled.
PRESERVE_PERMISSIONS="${PRESERVE_PERMISSIONS:-false}"
# AZURE_USE_MSI: call `az login --identity` at startup (set true for Container Jobs
# with an assigned managed identity; leave false when using an existing CLI session)
AZURE_USE_MSI="${AZURE_USE_MSI:-false}"

# Validate types
[[ "$SRC_TYPE" == "file" || "$SRC_TYPE" == "blob" ]] || \
  { echo "SRC_TYPE must be 'file' or 'blob'"; exit 1; }
[[ "$DST_TYPE" == "file" || "$DST_TYPE" == "blob" ]] || \
  { echo "DST_TYPE must be 'file' or 'blob'"; exit 1; }

# Normalise paths
SRC_PATH="${SRC_PATH%/}"
DST_PATH="${DST_PATH%/}"

# Run metadata
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-${SRC_SHARE}-${DST_SHARE}"
BASE_DIR="/tmp/azcopy-migration/$RUN_ID"
LOG_DIR="$BASE_DIR/logs"
PLAN_DIR="$BASE_DIR/plans"

mkdir -p "$LOG_DIR" "$PLAN_DIR"
export AZCOPY_LOG_LOCATION="$LOG_DIR"
export AZCOPY_JOB_PLAN_LOCATION="$PLAN_DIR"

# Helpers
log()  { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "ERROR: $*"; exit 1; }

trap 'fail "Script failed on line $LINENO."' ERR

# Azure CLI auth (managed identity for container environments)
if [[ "$AZURE_USE_MSI" == "true" ]]; then
  log "Logging in with managed identity."
  if [[ -n "${AZURE_CLIENT_ID:-}" ]]; then
    # AZURE_CLIENT_ID is set automatically by Container Apps for user-assigned identities
    az login --identity --username "$AZURE_CLIENT_ID" --output none
  else
    az login --identity --output none
  fi
fi

log "Starting migration run: $RUN_ID"
log "Source      : ${SRC_TYPE}://${SRC_ACCOUNT}/${SRC_SHARE}/${SRC_PATH}"
log "Destination : ${DST_TYPE}://${DST_ACCOUNT}/${DST_SHARE}/${DST_PATH:-<root>}"

az account show --output none

# Create destination share or container if it doesn't exist
if [[ "$DST_TYPE" == "blob" ]]; then
  log "Creating/verifying destination blob container."
  az storage container create \
    --account-name "$DST_ACCOUNT" \
    --name "$DST_SHARE" \
    --auth-mode login \
    --output none
else
  log "Creating/verifying destination file share (quota: ${SHARE_QUOTA_GB} GiB)."
  az storage share-rm create \
    --resource-group "$DST_RG" \
    --storage-account "$DST_ACCOUNT" \
    --name "$DST_SHARE" \
    --quota "$SHARE_QUOTA_GB" \
    --output none
fi

# ── Fetch account keys (used for snapshot and SAS generation) ──────────────────
log "Fetching storage account keys."

SRC_KEY="$(az storage account keys list \
  --resource-group "$SRC_RG" \
  --account-name "$SRC_ACCOUNT" \
  --query "[0].value" \
  -o tsv)"

DST_KEY="$(az storage account keys list \
  --resource-group "$DST_RG" \
  --account-name "$DST_ACCOUNT" \
  --query "[0].value" \
  -o tsv)"

# ── Snapshot source (file shares only) ────────────────────────────────────────
# Anchors the copy and verification to a consistent point in time.
# Blob containers have no equivalent share-level snapshot; copy runs against live data.
SNAPSHOT_TS=""
if [[ "$SRC_TYPE" == "file" ]]; then
  log "Taking source share snapshot."
  SNAPSHOT_TS="$(az storage share snapshot \
    --account-name "$SRC_ACCOUNT" \
    --account-key "$SRC_KEY" \
    --name "$SRC_SHARE" \
    --query snapshot \
    -o tsv)"
  [[ -n "$SNAPSHOT_TS" ]] || fail "Snapshot timestamp was empty."
  log "Snapshot created: $SNAPSHOT_TS"
else
  log "Source is blob storage — skipping snapshot; copy will run against live container."
fi

# ── Generate SAS tokens ────────────────────────────────────────────────────────
EXPIRY="$(date -u -d "${SAS_HOURS} hours" '+%Y-%m-%dT%H:%MZ')"
log "SAS expiry: $EXPIRY"

if [[ "$SRC_TYPE" == "blob" ]]; then
  # Blob container SAS: read + list
  SRC_SAS="$(az storage container generate-sas \
    --account-name "$SRC_ACCOUNT" \
    --account-key "$SRC_KEY" \
    --name "$SRC_SHARE" \
    --permissions rl \
    --expiry "$EXPIRY" \
    --https-only \
    -o tsv)"
else
  # File share SAS: read + list
  SRC_SAS="$(az storage share generate-sas \
    --account-name "$SRC_ACCOUNT" \
    --account-key "$SRC_KEY" \
    --name "$SRC_SHARE" \
    --permissions rl \
    --expiry "$EXPIRY" \
    --https-only \
    -o tsv)"
fi

if [[ "$DST_TYPE" == "blob" ]]; then
  # Blob container SAS: read, add, create, write, delete, list
  DST_SAS="$(az storage container generate-sas \
    --account-name "$DST_ACCOUNT" \
    --account-key "$DST_KEY" \
    --name "$DST_SHARE" \
    --permissions racwdl \
    --expiry "$EXPIRY" \
    --https-only \
    -o tsv)"
else
  # File share SAS: read, create, write, delete, list, update-metadata
  # Permissions must be in documented order: r,c,w,d,l,u
  # 'a' (append) is a Blob/Queue permission and is not valid for File Share SAS.
  DST_SAS="$(az storage share generate-sas \
    --account-name "$DST_ACCOUNT" \
    --account-key "$DST_KEY" \
    --name "$DST_SHARE" \
    --permissions cdlrw \
    --expiry "$EXPIRY" \
    --https-only \
    -o tsv)"
fi

# ── Build AzCopy URLs ──────────────────────────────────────────────────────────
SRC_HOST="${SRC_ACCOUNT}.$( [[ "$SRC_TYPE" == "blob" ]] && echo "blob" || echo "file" ).core.windows.net"
DST_HOST="${DST_ACCOUNT}.$( [[ "$DST_TYPE" == "blob" ]] && echo "blob" || echo "file" ).core.windows.net"

SRC_BASE="https://${SRC_HOST}/${SRC_SHARE}${SRC_PATH:+/$SRC_PATH}"
DST_BASE="https://${DST_HOST}/${DST_SHARE}${DST_PATH:+/$DST_PATH}"

# sharesnapshot only applies when we took a file share snapshot
SRC_SNAPSHOT_PARAM="${SNAPSHOT_TS:+&sharesnapshot=${SNAPSHOT_TS}}"

# Copy: /* places the CONTENTS of SRC_PATH into DST_BASE.
# Without /*, azcopy would create a sub-folder named after the last SRC_PATH component.
SRC_COPY_URL="${SRC_BASE}/*?${SRC_SAS}${SRC_SNAPSHOT_PARAM}"
DST_COPY_URL="${DST_BASE}?${DST_SAS}"

# # Sync (verification only): directory URL — azcopy sync treats both sides as trees
# SRC_SYNC_URL="${SRC_BASE}?${SRC_SAS}${SRC_SNAPSHOT_PARAM}"
# DST_SYNC_URL="${DST_BASE}/?${DST_SAS}"

# Build azcopy copy flags
# Explicit --from-to avoids the "Unknown protocol" warning and ensures azcopy uses
# the correct transfer path for cross-service (file <-> blob) copies.
src_svc=$([[ "$SRC_TYPE" == "blob" ]] && echo "Blob" || echo "File")
dst_svc=$([[ "$DST_TYPE" == "blob" ]] && echo "Blob" || echo "File")

COPY_FLAGS=(
  --recursive=true
  --check-length=true
  --log-level=INFO
  --from-to="${src_svc}${dst_svc}"
)

# Force block blobs when the destination is blob storage.
# AzCopy auto-detects .vhd/.vhdx as Page Blobs (Azure disk images), which requires
# 512-byte-aligned sizes. Non-disk files with those extensions fail with a 400.
# Block Blob is the correct type for archive use cases.
if [[ "$DST_TYPE" == "blob" ]]; then
  COPY_FLAGS+=(--blob-type=BlockBlob)
fi

# SMB info (timestamps, attributes) and permissions only apply to file-to-file copies
if [[ "$SRC_TYPE" == "file" && "$DST_TYPE" == "file" ]]; then
  COPY_FLAGS+=(--preserve-smb-info=true)

  if [[ "$PRESERVE_PERMISSIONS" == "true" ]]; then
    # Requires premium (large) file shares on both ends.
    # AzCopy must use OAuth (not SAS) for ACL transfer;
    # set AZCOPY_AUTO_LOGIN_TYPE=MSI if running under a managed identity.
    log "Warning: PRESERVE_PERMISSIONS=true — requires premium file shares and OAuth azcopy auth."
    COPY_FLAGS+=(--preserve-smb-permissions=true)
  fi
elif [[ "$PRESERVE_PERMISSIONS" == "true" ]]; then
  log "Warning: PRESERVE_PERMISSIONS=true ignored — SMB permissions require file-to-file copies."
fi

# AzCopy copy
log "Starting AzCopy copy (${SRC_TYPE} -> ${DST_TYPE})."
azcopy copy "$SRC_COPY_URL" "$DST_COPY_URL" "${COPY_FLAGS[@]}"
log "AzCopy copy completed."

log "AzCopy jobs:"
azcopy jobs list || true

log "Migration completed successfully."
[[ -n "$SNAPSHOT_TS" ]] && log "Source snapshot retained at: $SNAPSHOT_TS"