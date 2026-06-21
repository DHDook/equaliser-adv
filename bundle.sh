#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/.build/release"
EXECUTABLE_NAME="Equaliser"
APP_NAME="Notch Sixty"
RELEASE_DIR="$ROOT_DIR/release"
APP_BUNDLE="$RELEASE_DIR/${APP_NAME}.app"
INFO_PLIST_SRC="$ROOT_DIR/src/app/Info.plist"
ENTITLEMENTS="$ROOT_DIR/resources/Equaliser.entitlements"
ICON_SVG="$ROOT_DIR/resources/AppIcon-light.svg"
ICON_DARK_SVG="$ROOT_DIR/resources/AppIcon-dark.svg"
MENUBAR_SVG="$ROOT_DIR/resources/MenuBarIcon.svg"
ICONSET_DIR="$ROOT_DIR/.build/AppIcon.iconset"
ICON_ICNS="$ROOT_DIR/.build/AppIcon.icns"
ASSETS_CAR="$ROOT_DIR/.build/Assets.car"
DRIVER_BUNDLE="$ROOT_DIR/driver/.build/Equaliser.driver"

if [[ ! -f "$ROOT_DIR/Package.swift" ]]; then
  echo "Error: bundle.sh must run from repo root containing Package.swift" >&2
  exit 1
fi

generate_icon() {
  local LIGHT_SVG="$ROOT_DIR/resources/AppIcon-light.svg"
  local DARK_SVG="$ROOT_DIR/resources/AppIcon-dark.svg"
  local MENUBAR_SVG="$ROOT_DIR/resources/MenuBarIcon.svg"
  local APPICONSET="$ROOT_DIR/resources/AppIcon.xcassets/AppIcon.appiconset"

  for f in "$LIGHT_SVG" "$DARK_SVG" "$MENUBAR_SVG"; do
    if [[ ! -f "$f" ]]; then
      echo "Error: Missing icon file: $f" >&2; exit 1
    fi
  done

  if ! command -v rsvg-convert &>/dev/null; then
    echo "Error: rsvg-convert not found. Install: brew install librsvg" >&2; exit 1
  fi

  echo "Generating app icon PNGs..."
  mkdir -p "$APPICONSET"
  rm -f "$APPICONSET"/icon_*.png

  for size in 16 32 128 256 512; do
    local double=$((size * 2))
    rsvg-convert -w $size   -h $size   "$LIGHT_SVG" -o "$APPICONSET/icon_${size}x${size}.png"
    rsvg-convert -w $double -h $double "$LIGHT_SVG" -o "$APPICONSET/icon_${size}x${size}@2x.png"
    rsvg-convert -w $size   -h $size   "$DARK_SVG"  -o "$APPICONSET/icon_dark_${size}x${size}.png"
    rsvg-convert -w $double -h $double "$DARK_SVG"  -o "$APPICONSET/icon_dark_${size}x${size}@2x.png"
  done

  echo "Compiling Asset Catalog..."
  local ACTOOL_OUT="$ROOT_DIR/.build/actool-out"
  rm -rf "$ACTOOL_OUT" && mkdir -p "$ACTOOL_OUT"

  xcrun actool \
    --compile "$ACTOOL_OUT" \
    --platform macosx \
    --minimum-deployment-target 15.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$ROOT_DIR/.build/actool-partial.plist" \
    "$ROOT_DIR/resources/AppIcon.xcassets"

  ICON_ICNS="$ACTOOL_OUT/AppIcon.icns"
  ASSETS_CAR="$ACTOOL_OUT/Assets.car"

  if [[ ! -f "$ICON_ICNS" ]]; then
    echo "Error: actool did not produce AppIcon.icns" >&2; exit 1
  fi

  # driver.sh checks for the icon at .build/AppIcon.icns (its conventional
  # path). Copy it there so driver.sh finds it immediately and never
  # attempts to regenerate.
  cp "$ICON_ICNS" "$ROOT_DIR/.build/AppIcon.icns"

  echo "Icon assets ready."
}

build_driver() {
  if [[ ! -f "$ICON_ICNS" ]]; then
    echo "Error: Icon not found. Run: ./bundle.sh icon" >&2
    exit 1
  fi

  echo "Building virtual audio driver..."
  "$ROOT_DIR/driver/driver.sh" bundle --quiet
}

build_app() {
  if [[ ! -d "$DRIVER_BUNDLE" ]]; then
    echo "Error: Driver not found. Run: ./bundle.sh driver" >&2
    exit 1
  fi

  echo "Building Swift app..."
  swift build -c release

  echo "Creating app bundle at $APP_BUNDLE"
  rm -rf "$RELEASE_DIR"
  mkdir -p "$APP_BUNDLE/Contents/MacOS"
  mkdir -p "$APP_BUNDLE/Contents/Resources"

  cp "$BUILD_DIR/$EXECUTABLE_NAME" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
  cp "$INFO_PLIST_SRC" "$APP_BUNDLE/Contents/Info.plist"

  # Copy driver to app bundle
  cp -R "$DRIVER_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
  echo "Driver bundled with app"

  # Copy adaptive icon (Assets.car enables light/dark switching)
  if [[ -f "$ASSETS_CAR" ]]; then
    cp "$ASSETS_CAR" "$APP_BUNDLE/Contents/Resources/Assets.car"
    echo "Assets.car copied to app bundle"
  fi

  # Copy .icns (Finder/Dock fallback and driver icon source)
  if [[ -f "$ICON_ICNS" ]]; then
    cp "$ICON_ICNS" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo "AppIcon.icns copied to app bundle"
  fi

  # Menu bar template icon at 1× and 2× — NSImage(named:"MenuBarIcon") picks these up
  rsvg-convert -w 16 -h 16 "$ROOT_DIR/resources/MenuBarIcon.svg" \
    -o "$APP_BUNDLE/Contents/Resources/MenuBarIcon.png"
  rsvg-convert -w 32 -h 32 "$ROOT_DIR/resources/MenuBarIcon.svg" \
    -o "$APP_BUNDLE/Contents/Resources/MenuBarIcon@2x.png"
  echo "Menu bar icon generated"

  codesign --force --sign - --options runtime \
    --entitlements "$ENTITLEMENTS" \
    "$APP_BUNDLE"

  echo "Bundle created: $APP_BUNDLE"
  echo "You can now copy it to /Applications to run Notch Sixty normally."
}

show_usage() {
  echo "Usage: $0 [command]"
  echo ""
  echo "Commands:"
  echo "  (none)  - Full build: generate icon, build driver, build app"
  echo "  icon    - Generate icon only"
  echo "  driver  - Build driver only (requires icon)"
  echo "  app     - Build app only (requires driver)"
}

case "${1:-}" in
  icon)
    generate_icon
    ;;
  driver)
    build_driver
    ;;
  app)
    build_app
    ;;
  "")
    generate_icon
    build_driver
    build_app
    ;;
  *)
    show_usage
    exit 1
    ;;
esac

