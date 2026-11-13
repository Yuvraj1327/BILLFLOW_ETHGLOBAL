#!/usr/bin/env bash
# Build Flutter Web -> generate Vercel Build Output API dir -> deploy prebuilt to production.
# Usage: frontend/deploy/deploy.sh [--clean] [--no-deploy]
# Everything this script needs persists in frontend/deploy and frontend/web, neither of
# which `flutter clean` touches. Generated dirs (build/, .vercel/output) are rebuilt each run.
set -euo pipefail

FRONTEND="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY="$FRONTEND/deploy"
CLEAN=0; DO_DEPLOY=1
for a in "$@"; do
  case "$a" in
    --clean) CLEAN=1 ;;
    --no-deploy) DO_DEPLOY=0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

cd "$FRONTEND"
[ -f web/index.html ] || { echo "frontend/web/index.html missing (Flutter web source); restore it from git" >&2; exit 1; }
[ -f .env ] || { echo "frontend/.env missing (bundled as an asset)" >&2; exit 1; }
[ -f "$DEPLOY/vercel-output-config.json" ] || { echo "deploy/vercel-output-config.json missing" >&2; exit 1; }

if [ "$CLEAN" = 1 ]; then flutter clean; fi
flutter pub get
flutter build web --release

# Regenerate Vercel prebuilt output from the fresh build (config comes from deploy/, not build/).
rm -rf .vercel/output
mkdir -p .vercel/output
cp -R build/web .vercel/output/static
cp "$DEPLOY/vercel-output-config.json" .vercel/output/config.json
test -f .vercel/output/static/index.html && test -f .vercel/output/static/main.dart.js

if [ "$DO_DEPLOY" = 1 ]; then
  cd "$FRONTEND/.."   # repo root holds .vercel/repo.json (project dir = frontend)
  vercel deploy --prebuilt --prod --cwd frontend
else
  echo "Skipped deploy (--no-deploy). Output ready in frontend/.vercel/output"
fi
