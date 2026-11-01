#!/usr/bin/env bash
# Builds Wiretide.app from the Swift package, signs it, and zips it for Sparkle.
#
# Everything is configured through environment variables, so the same script serves local
# builds (ad-hoc signed) and CI releases (Developer ID, notarized):
#
#   VERSION            marketing version, e.g. 1.0.0        (default: latest v* tag, or 0.0.0)
#   BUILD_NUMBER       CFBundleVersion, must always increase  (default: git commit count)
#   BUNDLE_ID          bundle identifier; must match HelperIdentity.appBundleIdentifier (default: app.wiretide.Wiretide)
#   ARCHS              architectures                          (default: "arm64 x86_64")
#   RELEASE_DATE       yyyy-MM-dd, starts the license update window check (default: today, UTC)
#   SIGN_IDENTITY      codesign identity; "-" signs ad hoc    (default: -)
#   SU_FEED_URL        Sparkle appcast URL                    (optional; updates are off without it)
#   SU_PUBLIC_ED_KEY   Sparkle public EdDSA key               (optional; updates are off without it)
#   LS_STORE_ID, LS_PRODUCT_IDS, PURCHASE_URL                 (optional; Pro activation is off without them)
#   NOTARY_KEYCHAIN_PROFILE, or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD
#                      notarize and staple when set (requires a Developer ID SIGN_IDENTITY)
#   OUTPUT             output folder                          (default: dist)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)

VERSION=${VERSION:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//' || true)}
VERSION=${VERSION:-0.0.0}
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
BUNDLE_ID=${BUNDLE_ID:-app.wiretide.Wiretide}
ARCHS=${ARCHS:-arm64 x86_64}
RELEASE_DATE=${RELEASE_DATE:-$(date -u +%Y-%m-%d)}
SIGN_IDENTITY=${SIGN_IDENTITY:--}
OUTPUT=${OUTPUT:-dist}

APP="$OUTPUT/Wiretide.app"
ZIP="$OUTPUT/Wiretide-$VERSION.zip"

echo "==> Building Wiretide $VERSION ($BUILD_NUMBER) for $ARCHS"
# One native build per architecture, joined with lipo. (`swift build --arch a --arch b` switches to
# the Xcode build system, which fails on this package.)
BINARIES=()
HELPERS=()
for arch in $ARCHS; do
  triple="$arch-apple-macosx14.0"
  swift build -c release --product Wiretide --triple "$triple"
  swift build -c release --product WiretideHelper --triple "$triple"
  BIN=$(swift build -c release --triple "$triple" --show-bin-path)
  BINARIES+=("$BIN/Wiretide")
  HELPERS+=("$BIN/WiretideHelper")
done

echo "==> Assembling $APP"
rm -rf "$APP" "$ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/Wiretide"
lipo -create "${HELPERS[@]}" -output "$APP/Contents/MacOS/WiretideHelper"
cp Packaging/app.wiretide.Wiretide.Helper.plist "$APP/Contents/Library/LaunchDaemons/"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# SwiftPM resource bundles, if any target gains resources later.
find "$BIN" -maxdepth 1 -name '*.bundle' -exec ditto {} "$APP/Contents/Resources/" \; 2>/dev/null || true

PLIST="$APP/Contents/Info.plist"
cp Packaging/Info.plist "$PLIST"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$PLIST"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$PLIST"
plutil -replace NSHumanReadableCopyright -string "© $(date -u +%Y) Ryan Salim" "$PLIST"
plutil -replace TWReleaseDate -string "$RELEASE_DATE" "$PLIST"

set_or_remove() { # key value
  if [[ -n "$2" ]]; then plutil -replace "$1" -string "$2" "$PLIST"; else plutil -remove "$1" "$PLIST"; fi
}
set_or_remove SUFeedURL "${SU_FEED_URL:-}"
set_or_remove SUPublicEDKey "${SU_PUBLIC_ED_KEY:-}"
set_or_remove TWLemonSqueezyStoreID "${LS_STORE_ID:-}"
set_or_remove TWLemonSqueezyProductIDs "${LS_PRODUCT_IDS:-}"
set_or_remove TWPurchaseURL "${PURCHASE_URL:-}"
plutil -lint "$PLIST" >/dev/null

echo "==> Signing with identity: $SIGN_IDENTITY"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  SIGN=(codesign --force --sign -)
else
  SIGN=(codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY")
fi
# Inside out, as Sparkle documents: its XPC services and helpers first, then the framework, then the app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SPARKLE/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPARKLE/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Updater.app"
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" --identifier app.wiretide.Wiretide.Helper "$APP/Contents/MacOS/WiretideHelper"
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" || -n "${APPLE_ID:-}" ]]; then
  [[ "$SIGN_IDENTITY" != "-" ]] || { echo "Notarization needs a Developer ID SIGN_IDENTITY" >&2; exit 1; }
  echo "==> Notarizing"
  if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
  else
    xcrun notarytool submit "$ZIP" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
  fi
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  spctl --assess --type execute --verbose "$APP"
fi

echo "==> Done"
echo "$ROOT/$APP"
echo "$ROOT/$ZIP"
