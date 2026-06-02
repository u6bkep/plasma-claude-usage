#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PACKAGE="claude-usage-widget.plasmoid"

# Remove the old archive first; appending would leave stale entries inside.
rm -f "$PACKAGE"

echo "Building $PACKAGE..."

if command -v zip >/dev/null 2>&1; then
    zip -r "$PACKAGE" metadata.json contents/ -x '*.DS_Store' >/dev/null
elif command -v python3 >/dev/null 2>&1; then
    # A .plasmoid is a standard zip; build it with Python when zip is absent.
    python3 - "$PACKAGE" <<'PY'
import os, sys, zipfile
pkg = sys.argv[1]
with zipfile.ZipFile(pkg, "w", zipfile.ZIP_DEFLATED) as z:
    z.write("metadata.json")
    for root, dirs, files in os.walk("contents"):
        for name in files:
            if name == ".DS_Store":
                continue
            z.write(os.path.join(root, name))
PY
else
    echo "Error: need 'zip' or 'python3' to build the package." >&2
    exit 1
fi

echo ""
echo "Created $SCRIPT_DIR/$PACKAGE"
echo "Upload to https://store.kde.org/ or install with:"
echo "  kpackagetool6 --type Plasma/Applet --install $PACKAGE"
echo "  (use --upgrade instead of --install to update an existing install)"
