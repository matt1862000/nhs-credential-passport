#!/usr/bin/env bash
# SSL check for Zscaler-style acceptance: correct cert with and (where possible) without SNI.
# Run from repo root or website: ./scripts/check-ssl-zscaler.sh

set -e
HOST="${1:-www.wewaitwell.com}"

echo "=== SSL diagnostic for Zscaler-style acceptance ==="
echo "Host: $HOST"
echo ""

# 1. With SNI (normal case – browsers and most clients)
echo "1. With SNI (normal clients):"
echo "   Expected: subject CN = wewaitwell.com or your domain"
SUBJECT=$(echo | openssl s_client -connect "$HOST:443" -servername "$HOST" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)
if [ -n "$SUBJECT" ]; then
  echo "   Result: $SUBJECT"
  if echo "$SUBJECT" | grep -q "wewaitwell"; then
    echo "   Status: OK (correct cert for your domain)"
  else
    echo "   Status: WARN (unexpected CN)"
  fi
else
  echo "   Result: (failed to get cert)"
  echo "   Status: FAIL"
fi
echo ""

# 2. Connect by IP without SNI (simulates strict proxy / no-SNI)
# When Zscaler strips or doesn't send SNI, the server may return a fallback cert (e.g. no-sni.vercel-infra.com).
# If Cloudflare proxy is ON, Cloudflare terminates TLS and the client (Zscaler) only sees Cloudflare's cert.
IP=$(dig +short "$HOST" A 2>/dev/null | head -1)
if [ -z "$IP" ]; then
  echo "2. No-SNI check: skipped (could not resolve $HOST)"
else
  echo "2. Connect by IP (no SNI) – simulates what strict proxies can see:"
  echo "   IP: $IP"
  echo "   If you see no-sni.vercel-infra.com → Zscaler may flag."
  echo "   If you see wewaitwell.com or Cloudflare → Zscaler should accept."
  # -noservername not supported on macOS LibreSSL; use connect-by-IP only (may still send SNI on some systems)
  NO_SNI=$(echo | openssl s_client -connect "$IP:443" -noservername 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)
  [ -z "$NO_SNI" ] && NO_SNI=$(echo | openssl s_client -connect "$IP:443" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)
  if [ -n "$NO_SNI" ]; then
    echo "   Result: $NO_SNI"
    if echo "$NO_SNI" | grep -qi "no-sni.vercel-infra"; then
      echo "   Status: WARN (fallback cert – enable Cloudflare proxy + Full Strict)"
    elif echo "$NO_SNI" | grep -q "wewaitwell\|cloudflare"; then
      echo "   Status: OK (expected cert)"
    else
      echo "   Status: CHECK (unexpected CN)"
    fi
  else
    echo "   Result: (no cert / connection failed – server may require SNI)"
    echo "   Status: With Cloudflare proxy ON, Zscaler only talks to Cloudflare; re-check from behind Zscaler."
  fi
fi
echo ""

# 3. Quick HTTP check
echo "3. HTTPS reachability:"
if curl -sI --connect-timeout 5 "https://$HOST" | head -1 | grep -q "200\|301\|302"; then
  echo "   OK (site responds)"
else
  echo "   FAIL or timeout"
fi
echo ""
echo "=== Summary ==="
echo "• With SNI: correct domain in subject → normal clients and Zscaler (when SNI is sent) are OK."
echo "• No SNI: if you see no-sni.vercel-infra.com, enable Cloudflare proxy (orange cloud) + SSL Full (Strict)."
echo "• Definitive test: open https://$HOST from a device behind Zscaler and confirm no cert warning."
