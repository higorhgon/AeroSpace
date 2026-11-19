#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -d "$1/AeroSpace.app" ]]; then
    echo "Usage: $0 <directory containing AeroSpace.app>" >&2
    exit 1
fi

release_dir="${1%/}"
staging="$(mktemp -d)"
trap 'rm -rf -- "$staging"' EXIT

/usr/bin/ditto "$release_dir" "$staging"
ln -s /Applications "$staging/Applications"
/usr/bin/hdiutil create -srcfolder "$staging" -volname AeroSpace -fs HFS+ -format UDZO "${release_dir}.dmg"
/usr/bin/hdiutil verify "${release_dir}.dmg"
