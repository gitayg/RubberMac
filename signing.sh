# Sourced by build.sh, dmg.sh and release.sh. Which Developer ID signs the app belongs to this Mac, not to the repo:
# put the certificate's name, or a part of it that only it has, in .signing-identity (ignored by git), or set
# SIGNING_IDENTITY.
NAME="${SIGNING_IDENTITY:-$(cat .signing-identity 2>/dev/null || true)}"
[ -n "$NAME" ] || { echo "No signing identity: put your Developer ID certificate's name in .signing-identity"; exit 1; }
IDENTITY=$(security find-identity -v -p codesigning | awk -v name="$NAME" 'index($0, name) {print $2; exit}')
[ -n "$IDENTITY" ] || { echo "No certificate on this Mac matches '$NAME'"; exit 1; }
