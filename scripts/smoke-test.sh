#!/usr/bin/env bash
# End-to-end routing + upload smoke test. Hits the Traefik Ingress on the
# control-plane IP (default 192.168.30.134) with the Biashara OS Host header.
#
# Env overrides:
#   HOST         Host header (default biasharaos.home)
#   INGRESS_IP   control-plane IP where Traefik listens (default 192.168.30.134)
set -euo pipefail

HOST="${HOST:-biasharaos.home}"
INGRESS_IP="${INGRESS_IP:-192.168.30.134}"
NAMESPACE="${NAMESPACE:-biasharaos}"

ok() { echo "✓ $*"; }
die() { echo "✗ $*" >&2; exit 1; }

echo "--- GET / via Traefik (expect 200) ---"
STATUS=$(curl -sk -o /dev/null -w "%{http_code}" -H "Host: $HOST" "http://$INGRESS_IP/")
[ "$STATUS" = "200" ] && ok "ingress returned 200" || die "ingress returned $STATUS"

echo "--- GET /api/dashboard (expect 200 JSON) ---"
BODY=$(curl -sk -H "Host: $HOST" "http://$INGRESS_IP/api/dashboard" | head -c 200)
echo "   first 200 bytes: $BODY"

echo "--- Fetch invoice token (constant-time compare on server) ---"
TOKEN=$(kubectl get secret biasharaos-invoice-token -n "$NAMESPACE" \
          -o jsonpath='{.data.INVOICE_UPLOAD_TOKEN}' | base64 -d)
[ -n "$TOKEN" ] || die "invoice token missing"

echo "--- Prepare a tiny real PDF ---"
if [ ! -f /tmp/test-invoice.pdf ]; then
  python3 - <<'PY'
with open('/tmp/test-invoice.pdf', 'wb') as f:
    f.write(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n")
PY
fi

echo "--- POST /api/invoices/upload (expect 201) ---"
STATUS=$(curl -sk -o /tmp/upload.out -w "%{http_code}" -X POST \
  -H "Host: $HOST" \
  -H "x-upload-token: $TOKEN" \
  -H "Content-Type: application/pdf" \
  --data-binary @/tmp/test-invoice.pdf \
  "http://$INGRESS_IP/api/invoices/upload")
echo "   response: $(cat /tmp/upload.out)"
unset TOKEN
[ "$STATUS" = "201" ] && ok "upload accepted (201)" || die "upload returned $STATUS"

echo
ok "All checks passed."
