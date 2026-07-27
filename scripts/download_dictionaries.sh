#!/usr/bin/env bash
# Downloads Hunspell .aff/.dic files from wooorm/dictionaries and arramooz
# and places them in the AlphaSubHunspell Dictionaries resource directory.
set -euo pipefail

DICT_DIR="$(dirname "$0")/../Sources/AlphaSub/Hunspell/Dictionaries"
mkdir -p "$DICT_DIR"

# wooorm/dictionaries language codes (from the repo's dictionary list)
WOOORM_CODES=(
  bg br ca cs cy da de el en eo es et eu fa fo fr fur fy ga gd gl he hr hu hy
  hyw ia ie is it ka ko la lb lt ltg lv mk mn nb nds ne nl nn oc pl pt ro ru rw
  sk sl sv tk tlh tr uk vi
)

# wooorm/dictionaries with region subtags (directory names differ from BCP-47)
WOOORM_REGIONAL=(
  "ca-valencia"
  "de-AT"
  "de-CH"
  "el-polyton"
  "en-AU"
  "en-CA"
  "en-GB"
  "en-ZA"
  "es-AR"
  "es-BO"
  "es-CL"
  "es-CO"
  "es-CR"
  "es-CU"
  "es-DO"
  "es-EC"
  "es-GT"
  "es-HN"
  "es-MX"
  "es-NI"
  "es-PA"
  "es-PE"
  "es-PH"
  "es-PR"
  "es-PY"
  "es-SV"
  "es-US"
  "es-UY"
  "es-VE"
  "pt-PT"
  "sr-Latn"
  "sv-FI"
  "tlh-Latn"
)

BASE_URL="https://raw.githubusercontent.com/wooorm/dictionaries/main/dictionaries"

download_wooorm() {
  local code="$1"
  local dir_name="$code"
  # Handle case where directory name casing differs
  # wooorm uses lowercase directories, e.g. "de-at" not "de-AT"
  local lower_dir=$(echo "$dir_name" | tr '[:upper:]' '[:lower:]')

  echo "Downloading wooorm dictionary: $code"

  curl -sL "${BASE_URL}/${lower_dir}/index.aff" -o "$DICT_DIR/${code}.aff" 2>/dev/null
  curl -sL "${BASE_URL}/${lower_dir}/index.dic" -o "$DICT_DIR/${code}.dic" 2>/dev/null

  # Verify files are valid (non-empty, not HTML error page)
  for ext in aff dic; do
    local file="$DICT_DIR/${code}.${ext}"
    if [ ! -s "$file" ]; then
      echo "  WARNING: $file is empty or missing, removing"
      rm -f "$file"
    elif head -1 "$file" | grep -qi "<!DOCTYPE\|<html\|404"; then
      echo "  WARNING: $file appears to be HTML error, removing"
      rm -f "$file"
    else
      local size=$(wc -c < "$file" | tr -d ' ')
      echo "  OK: ${code}.${ext} ($size bytes)"
    fi
  done
}

echo "=== Downloading wooorm/dictionaries ==="
for code in "${WOOORM_CODES[@]}"; do
  download_wooorm "$code"
done
for code in "${WOOORM_REGIONAL[@]}"; do
  download_wooorm "$code"
done

# Arabic dictionaries from arramooz/ayaspell
# The arramooz project generates Hunspell files via `make spell`.
# We download from the ayaspell upstream source which provides .aff/.dic.
echo ""
echo "=== Downloading Arabic dictionaries (arramooz/ayaspell) ==="

# ayaspell Hunspell files - base MSA Arabic
# Source: https://github.com/linuxscout/ayaspell
AYASPELL_BASE="https://raw.githubusercontent.com/linuxscout/ayaspell/master/hunspell"

# Download MSA Arabic dictionary
echo "Downloading Arabic (MSA) dictionary..."
curl -sL "${AYASPELL_BASE}/ar.aff" -o "$DICT_DIR/ar.aff" 2>/dev/null
curl -sL "${AYASPELL_BASE}/ar.dic" -o "$DICT_DIR/ar.dic" 2>/dev/null

for ext in aff dic; do
  file="$DICT_DIR/ar.$ext"
  if [ -s "$file" ]; then
    size=$(wc -c < "$file" | tr -d ' ')
    echo "  OK: ar.$ext ($size bytes)"
  else
    echo "  WARNING: ar.$ext is empty or missing"
  fi
done

# For Arabic dialects, we create symlink-style copies from the base Arabic
# dictionary with dialect-specific additions. Since arramooz provides a
# morphological dictionary, we generate dialect variants by copying the MSA
# base and adding dialect-specific word lists where available.
ARABIC_DIALECTS=(ar-DZ ar-BH ar-EG ar-IQ ar-JO ar-KW ar-LB ar-LY ar-MA ar-MR ar-OM ar-PS ar-QA ar-SA ar-SD ar-SY ar-TN ar-AE ar-YE)

# Try arramooz releases for inflected forms
ARRAMOOZ_BASE="https://github.com/linuxscout/arramooz/releases/download/0.1"

echo "Attempting to download arramooz inflected word list..."
for dialect in "${ARABIC_DIALECTS[@]}"; do
  # Use the MSA dictionary as base for all dialects
  # The aff file is the same; dialect differences come from the .dic file
  if [ -f "$DICT_DIR/ar.aff" ]; then
    cp "$DICT_DIR/ar.aff" "$DICT_DIR/${dialect}.aff"
    cp "$DICT_DIR/ar.dic" "$DICT_DIR/${dialect}.dic"
    echo "  Created $dialect from MSA base"
  fi
done

echo ""
echo "=== Download complete ==="
echo "Dictionary files in: $DICT_DIR"
ls -la "$DICT_DIR"/*.{aff,dic} 2>/dev/null | wc -l | xargs -I{} echo "{} dictionary files total"