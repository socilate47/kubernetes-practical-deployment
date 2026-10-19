#!/usr/bin/env bash
# Create the two Kubernetes Secrets Biashara OS needs, from values in a local
# .env file (git-ignored). INVOICE_UPLOAD_TOKEN is auto-generated if empty.
#
# Run from the repo root on a host that has kubectl pointed at the cluster.
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"
NAMESPACE="${NAMESPACE:-biasharaos}"

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE. Copy .env.example to .env and fill it in." >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

# Fail early on anything we actually require.
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is empty in $ENV_FILE}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is empty in $ENV_FILE}"
: "${S3_ENDPOINT:?S3_ENDPOINT is empty in $ENV_FILE}"
AWS_REGION="${AWS_REGION:-us-east-1}"
S3_BUCKET="${S3_BUCKET:-biasharaos-uploads}"
S3_FORCE_PATH_STYLE="${S3_FORCE_PATH_STYLE:-true}"

# Make sure the namespace is there (idempotent).
kubectl apply -f k8s/namespace.yaml

echo "--- biasharaos-s3 ---"
kubectl create secret generic biasharaos-s3 -n "$NAMESPACE" \
  --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  --from-literal=AWS_REGION="$AWS_REGION" \
  --from-literal=S3_ENDPOINT="$S3_ENDPOINT" \
  --from-literal=S3_BUCKET="$S3_BUCKET" \
  --from-literal=S3_FORCE_PATH_STYLE="$S3_FORCE_PATH_STYLE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "--- biasharaos-invoice-token ---"
GENERATED="no"
if [ -z "${INVOICE_UPLOAD_TOKEN:-}" ]; then
  INVOICE_UPLOAD_TOKEN="$(openssl rand -hex 32)"
  GENERATED="yes"
fi
kubectl create secret generic biasharaos-invoice-token -n "$NAMESPACE" \
  --from-literal=INVOICE_UPLOAD_TOKEN="$INVOICE_UPLOAD_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo
echo "Secrets applied to namespace $NAMESPACE."
echo "INVOICE_UPLOAD_TOKEN was $( [ "$GENERATED" = yes ] && echo 'generated (hex32)' || echo 'taken from .env')."
echo "Retrieve it any time with:"
echo "  kubectl get secret biasharaos-invoice-token -n $NAMESPACE -o jsonpath='{.data.INVOICE_UPLOAD_TOKEN}' | base64 -d"
