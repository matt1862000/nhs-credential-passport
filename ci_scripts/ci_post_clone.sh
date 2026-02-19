#!/bin/sh
set -e
# Xcode Cloud: Secrets.xcconfig is gitignored; create from example so the project can build.
if [ ! -f "Secrets.xcconfig" ]; then
  cp Secrets.xcconfig.example Secrets.xcconfig
  echo "Created Secrets.xcconfig from example for Xcode Cloud build."
fi
