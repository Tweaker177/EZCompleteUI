#!/bin/bash
set -e

APP_NAME="EZCompleteUI"
STAGED_APP=".theos/_/Applications/${APP_NAME}.app"
STAGED_PLIST="${STAGED_APP}/Info.plist"
SAVED_APP="/tmp/${APP_NAME}_patched.app"
export XDG_CACHE_HOME="${PWD}/.cache"
mkdir -p "${XDG_CACHE_HOME}/clang/ModuleCache"

# ─────────────────────────────────────────────────────────────────────────────
# patch_plist <path>
# ─────────────────────────────────────────────────────────────────────────────
patch_plist() {
    local target="$1"
    echo "  Patching: ${target}"
    python3 - "${target}" <<'PYEOF'
import plistlib, sys
path = sys.argv[1]
try:
    with open(path, 'rb') as f:
        d = plistlib.load(f)
except Exception as e:
    print(f"ERROR reading plist: {e}", file=sys.stderr)
    sys.exit(1)
d["NSMicrophoneUsageDescription"] = "EZCompleteUI uses the microphone for voice dictation."
d["NSSpeechRecognitionUsageDescription"] = "EZCompleteUI uses speech recognition to transcribe your voice."
d["NSDocumentsFolderUsageDescription"] = "EZCompleteUI needs access to your files so you can attach documents, images, and audio to your chats."
d['UIFileSharingEnabled'] = True
d['LSSupportsOpeningDocumentsInPlace'] = True
# UISupportsDocumentBrowser = True breaks UIDocumentPickerViewController on iOS 15 — remove it
d.pop('UISupportsDocumentBrowser', None)
with open(path, 'wb') as f:
    plistlib.dump(d, f)
keys = [k for k in d if 'Usage' in k]
print(f"  Injected {len(keys)} key(s): {keys}")
assert 'NSMicrophoneUsageDescription' in d
assert 'NSSpeechRecognitionUsageDescription' in d
assert 'NSDocumentsFolderUsageDescription' in d
assert d.get('UIFileSharingEnabled') == True
assert 'UISupportsDocumentBrowser' not in d, "UISupportsDocumentBrowser must be removed"
PYEOF
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. Compile + stage
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> [1/5] Compiling..."
make clean && make stage

# ─────────────────────────────────────────────────────────────────────────────
# 2. Patch staged plist
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> [2/5] Patching Info.plist..."
patch_plist "${STAGED_PLIST}"

# ─────────────────────────────────────────────────────────────────────────────
# 3. Save a copy of the patched app BEFORE make package wipes staging
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> [3/5] Saving patched app bundle..."
rm -rf "${SAVED_APP}"
cp -r "${STAGED_APP}" "${SAVED_APP}"
echo "  Saved to ${SAVED_APP}"

# ─────────────────────────────────────────────────────────────────────────────
# 4. Build IPA from saved patched app
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> [4/5] Building IPA..."
rm -rf Payload
mkdir -p Payload
cp -r "${SAVED_APP}" "Payload/${APP_NAME}.app"
zip -r9 "${APP_NAME}.ipa" Payload > /dev/null
rm -rf Payload
echo "  ${APP_NAME}.ipa ready"

# ─────────────────────────────────────────────────────────────────────────────
# 5. Build .deb
#
# make package re-stages and overwrites .theos/_/ — that's fine now because
# we already have our patched copy in /tmp. After make package produces the
# deb, we extract it with dpkg-deb, swap in our patched app, rebuild with
# dpkg-deb --build which produces a guaranteed-valid Debian archive.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> [5/5] Building .deb..."
make package FINALPACKAGE=1

DEB=$(ls -t packages/*.deb 2>/dev/null | head -1)
if [ -z "${DEB}" ]; then
    echo "ERROR: No .deb found in packages/ after make package"
    exit 1
fi
echo "  Theos built: ${DEB}"
echo "  Repacking with patched plist..."

WORK="$(mktemp -d)"
trap "rm -rf '${WORK}'" EXIT

# Extract the full deb contents using dpkg-deb (reliable, no ar needed)
DEB_ROOT="${WORK}/deb_root"
mkdir -p "${DEB_ROOT}"
dpkg-deb --extract "${DEB}" "${DEB_ROOT}"
dpkg-deb --control "${DEB}" "${DEB_ROOT}/DEBIAN"

# Rootless jailbreaks (Dopamine, palera1n) install to /var/jb/Applications
# Remove any /Applications path Theos may have staged and use correct rootless path
rm -rf "${DEB_ROOT}/Applications"
rm -rf "${DEB_ROOT}/var/jb/Applications/${APP_NAME}.app"
mkdir -p "${DEB_ROOT}/var/jb/Applications"
cp -r "${SAVED_APP}" "${DEB_ROOT}/var/jb/Applications/${APP_NAME}.app"

# Make sure DEBIAN scripts are executable
chmod 755 "${DEB_ROOT}/DEBIAN/"* 2>/dev/null || true

# Verify plist is patched inside deb root before repacking
echo "  Verifying plist in deb root..."
python3 << PYEOF
import plistlib, sys
path = "${DEB_ROOT}/var/jb/Applications/${APP_NAME}.app/Info.plist"
with open(path, 'rb') as f:
    d = plistlib.load(f)
mic    = d.get('NSMicrophoneUsageDescription', 'MISSING')
speech = d.get('NSSpeechRecognitionUsageDescription', 'MISSING')
docs   = d.get('NSDocumentsFolderUsageDescription', 'MISSING')
print(f"  Mic:    {mic[:60]}")
print(f"  Speech: {speech[:60]}")
print(f"  Docs:   {docs[:60]}")
if mic == 'MISSING' or speech == 'MISSING':
    print("ERROR: keys missing from deb root plist!", file=sys.stderr)
    sys.exit(1)
PYEOF

# Rebuild with dpkg-deb — always produces a valid Debian binary archive
dpkg-deb --build --root-owner-group "${DEB_ROOT}" "${DEB}"
echo "  ${DEB} ready"

# Final validation
echo "  Validating deb..."
dpkg-deb --info "${DEB}" | grep -E "Package|Version|Architecture|Installed-Size" | sed 's/^/    /'

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup + Summary
# ─────────────────────────────────────────────────────────────────────────────
rm -rf "${SAVED_APP}"

VERSION=$(python3 -c "
import plistlib
with open('${STAGED_APP}/Info.plist', 'rb') as f:
    d = plistlib.load(f)
print(d.get('CFBundleShortVersionString', '1.0'))
" 2>/dev/null || echo "1.0")

echo ""
echo "╔══════════════════════════════════════════════════════╗"
printf  "║  Build Complete  v%-35s║\n" "${VERSION}"
echo "╠══════════════════════════════════════════════════════╣"
printf  "║  IPA  %-47s║\n" "${APP_NAME}.ipa"
printf  "║  DEB  %-47s║\n" "${DEB}"
echo "╚══════════════════════════════════════════════════════╝"
