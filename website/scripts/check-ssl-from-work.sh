#!/usr/bin/env bash
# Run this on your WORK Mac/Linux (behind Zscaler) to see which cert Zscaler sees.
# Terminal: chmod +x check-ssl-from-work.sh && ./check-ssl-from-work.sh

HOST="${1:-www.wewaitwell.com}"

echo "=== SSL check from this machine (through Zscaler) ==="
echo "Host: $HOST"
echo ""

SUBJECT=$(echo | openssl s_client -connect "$HOST:443" -servername "$HOST" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)
ISSUER=$(echo | openssl s_client -connect "$HOST:443" -servername "$HOST" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)

if [ -z "$SUBJECT" ]; then
  echo "Could not get certificate (connection failed or no OpenSSL)."
  echo "Try in browser: https://$HOST"
  exit 1
fi

echo "Certificate SUBJECT (CN): $SUBJECT"
echo "Certificate ISSUER:        $ISSUER"
echo ""

if echo "$SUBJECT" | grep -q "no-sni.vercel-infra.com"; then
  echo "Result: Zscaler is seeing Vercel FALLBACK cert - that's what it flags."
  echo "Fix: Enable Cloudflare proxy (orange cloud) + SSL Full (Strict) for wewaitwell.com"
elif echo "$SUBJECT" | grep -q "wewaitwell"; then
  echo "Result: Correct cert (wewaitwell.com) - Zscaler should accept."
else
  echo "Result: Cert CN above - check if expected (e.g. Cloudflare)."
fi

echo ""
echo "Done. Share the SUBJECT/ISSUER lines if you need help."
