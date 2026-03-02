#!/usr/bin/env bash
# Deploy NHS Credential Passport to Fly.io
# Run once: fly auth login   (then run this script)
set -e
cd "$(dirname "$0")"
export PATH="$HOME/.fly/bin:$PATH"

# Create app and deploy if not already
if ! fly status 2>/dev/null; then
  fly launch --name nhs-credential-passport --region lhr --copy-config --now
else
  fly deploy
fi

# Set BASE_URL to your app URL (e.g. https://nhs-credential-passport.fly.dev)
APP_URL="https://nhs-credential-passport.fly.dev"
fly secrets set BASE_URL="$APP_URL" 2>/dev/null || true

echo ""
echo "Deployed. Open: $APP_URL"
echo "Staff app: $APP_URL/static/staff/"
echo "Verifier:  $APP_URL/static/verifier/"
