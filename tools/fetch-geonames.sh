#!/usr/bin/env bash
# Fetch the GeoNames city-level extract for the Phase 4.4 offline reverse-geocoding stage.
# Downloads into .models/Resources/geonames/ (gitignored — run once at dev setup; the build
# tolerates its absence and make-app.sh injects whatever is there). NO network at runtime.
#
# DATA LICENSE: GeoNames is licensed CC BY 4.0 — redistribution allowed, ATTRIBUTION REQUIRED.
#   "Place data © GeoNames (https://www.geonames.org), CC BY 4.0."
#   This attribution is surfaced in the app's About/credits and documented in catalog-schema.md.
#
# Usage: tools/fetch-geonames.sh [tier]   # tier: cities15000 (default, ~6MB) | cities5000 (~12MB)
set -euo pipefail
TIER="${1:-cities15000}"
BASE="https://download.geonames.org/export/dump"
DEST="$(cd "$(dirname "$0")/.." && pwd)/.models/Resources/geonames"
mkdir -p "$DEST"
echo "Fetching ${TIER}.zip ..."
curl -fL --retry 3 -o "${DEST}/${TIER}.zip" "${BASE}/${TIER}.zip"
( cd "$DEST" && unzip -o "${TIER}.zip" "${TIER}.txt" && mv "${TIER}.txt" "cities15000.txt" 2>/dev/null || true )
rm -f "${DEST}/${TIER}.zip"
for f in admin1CodesASCII.txt countryInfo.txt; do
  echo "Fetching ${f} ..."
  curl -fL --retry 3 -o "${DEST}/${f}" "${BASE}/${f}"
done
echo "Done -> ${DEST}"
echo "Place data © GeoNames, CC BY 4.0 — https://www.geonames.org (attribution required)."
