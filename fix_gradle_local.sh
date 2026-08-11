#!/usr/bin/env bash
set -Eeuo pipefail

# BambuRFID Gradle offline/local bootstrap helper
# Usage:
#   chmod +x fix_gradle_local.sh
#   ./fix_gradle_local.sh
# Or:
#   ./fix_gradle_local.sh /home/BambuRFID
#
# Optional:
#   GRADLE_VERSION=9.3.1 ./fix_gradle_local.sh /home/BambuRFID

PROJECT_DIR="${1:-$(pwd)}"
GRADLE_VERSION="${GRADLE_VERSION:-9.3.1}"

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
WRAPPER_PROPS="$PROJECT_DIR/android/gradle/wrapper/gradle-wrapper.properties"
GRADLEW="$PROJECT_DIR/android/gradlew"

if [[ ! -f "$WRAPPER_PROPS" ]]; then
  echo "ERROR: Cannot find:"
  echo "  $WRAPPER_PROPS"
  echo
  echo "Run this script from the BambuRFID project root, or pass the project path:"
  echo "  ./fix_gradle_local.sh /home/BambuRFID"
  exit 1
fi

if [[ ! -f "$GRADLEW" ]]; then
  echo "ERROR: Cannot find:"
  echo "  $GRADLEW"
  exit 1
fi

command -v curl >/dev/null 2>&1 || {
  echo "ERROR: curl is required."
  exit 1
}

command -v unzip >/dev/null 2>&1 || {
  echo "ERROR: unzip is required."
  echo "Install it first, e.g.: sudo apt-get install -y unzip"
  exit 1
}

DIST_DIR="$PROJECT_DIR/tool/gradle-dist"
ZIP_NAME="gradle-${GRADLE_VERSION}-bin.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
SHA_PATH="$DIST_DIR/${ZIP_NAME}.sha256"

DIRECT_URL="https://downloads.gradle.org/distributions/$ZIP_NAME"
SHA_URL="${DIRECT_URL}.sha256"

mkdir -p "$DIST_DIR"

echo "============================================================"
echo " BambuRFID Gradle local bootstrap"
echo "============================================================"
echo "Project : $PROJECT_DIR"
echo "Gradle  : $GRADLE_VERSION"
echo "Target  : $ZIP_PATH"
echo

download_zip() {
  local tmp="${ZIP_PATH}.part"

  rm -f "$tmp"

  echo "[1/5] Downloading Gradle from the direct Gradle distribution host..."
  echo "      $DIRECT_URL"
  echo

  curl \
    --fail \
    --location \
    --retry 5 \
    --retry-delay 2 \
    --retry-all-errors \
    --connect-timeout 15 \
    --speed-time 30 \
    --speed-limit 1024 \
    --progress-bar \
    -o "$tmp" \
    "$DIRECT_URL"

  mv "$tmp" "$ZIP_PATH"
}

if [[ -s "$ZIP_PATH" ]]; then
  echo "[1/5] Existing Gradle ZIP found; reusing it:"
  echo "      $ZIP_PATH"
else
  download_zip
fi

echo
echo "[2/5] Checking ZIP integrity..."
if ! unzip -tq "$ZIP_PATH" >/dev/null; then
  echo "ERROR: ZIP is corrupted. Removing it."
  rm -f "$ZIP_PATH"
  exit 1
fi
echo "      ZIP OK"

echo
echo "[3/5] Verifying SHA-256 when available..."

EXPECTED_SHA=""

# Prefer Gradle's published checksum.
if curl \
  --fail \
  --location \
  --retry 3 \
  --connect-timeout 10 \
  --silent \
  --show-error \
  -o "${SHA_PATH}.tmp" \
  "$SHA_URL"; then

  EXPECTED_SHA="$(tr -d '[:space:]' < "${SHA_PATH}.tmp" | awk '{print $1}')"

  if [[ "$EXPECTED_SHA" =~ ^[0-9a-fA-F]{64}$ ]]; then
    mv "${SHA_PATH}.tmp" "$SHA_PATH"
  else
    rm -f "${SHA_PATH}.tmp"
    EXPECTED_SHA=""
  fi
else
  rm -f "${SHA_PATH}.tmp"
fi

# If checksum download is unavailable, reuse the wrapper's configured hash.
if [[ -z "$EXPECTED_SHA" ]]; then
  EXPECTED_SHA="$(grep -E '^distributionSha256Sum=' "$WRAPPER_PROPS" 2>/dev/null \
    | head -n1 | cut -d= -f2- | tr -d '[:space:]' || true)"
fi

ACTUAL_SHA="$(sha256sum "$ZIP_PATH" | awk '{print $1}')"

if [[ -n "$EXPECTED_SHA" ]]; then
  if [[ "${ACTUAL_SHA,,}" != "${EXPECTED_SHA,,}" ]]; then
    echo "ERROR: SHA-256 mismatch!"
    echo "Expected: $EXPECTED_SHA"
    echo "Actual  : $ACTUAL_SHA"
    rm -f "$ZIP_PATH"
    exit 1
  fi
  echo "      SHA-256 OK: $ACTUAL_SHA"
else
  echo "      No published/configured checksum was available."
  echo "      Local SHA-256: $ACTUAL_SHA"
fi

echo
echo "[4/5] Pointing Gradle Wrapper to the local ZIP..."

cp -a "$WRAPPER_PROPS" "${WRAPPER_PROPS}.bak.$(date +%Y%m%d_%H%M%S)"

# Gradle properties use URI syntax. Absolute Linux paths become file:///...
LOCAL_URI="file\\://${ZIP_PATH}"

python3 - "$WRAPPER_PROPS" "$LOCAL_URI" "$ACTUAL_SHA" <<'PY'
from pathlib import Path
import sys

props_path = Path(sys.argv[1])
local_uri = sys.argv[2]
sha = sys.argv[3]

lines = props_path.read_text(encoding="utf-8").splitlines()

new_lines = []
seen_url = False
seen_sha = False

for line in lines:
    if line.startswith("distributionUrl="):
        new_lines.append(f"distributionUrl={local_uri}")
        seen_url = True
    elif line.startswith("distributionSha256Sum="):
        new_lines.append(f"distributionSha256Sum={sha}")
        seen_sha = True
    else:
        new_lines.append(line)

if not seen_url:
    new_lines.append(f"distributionUrl={local_uri}")

if not seen_sha:
    new_lines.append(f"distributionSha256Sum={sha}")

props_path.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
PY

chmod +x "$GRADLEW"

echo
echo "Wrapper configuration:"
grep -E '^(distributionUrl|distributionSha256Sum)=' "$WRAPPER_PROPS" || true

echo
echo "[5/5] Testing Gradle Wrapper..."
echo

cd "$PROJECT_DIR"
"$GRADLEW" --version

echo
echo "============================================================"
echo " Gradle local bootstrap completed successfully."
echo "============================================================"
echo
echo "The Gradle ZIP is stored at:"
echo "  $ZIP_PATH"
echo
echo "Now build BambuRFID with:"
echo "  cd \"$PROJECT_DIR\""
echo "  flutter clean"
echo "  flutter pub get"
echo "  flutter build apk --release"
echo
echo "To restore the old wrapper configuration, use the newest:"
echo "  $WRAPPER_PROPS.bak.*"
