#!/bin/sh
# Rebuilds the raccoon companion's layer strips and raccoon.json in
# Packaging/Raccoon from the pose sheet and descriptions in Artwork/Raccoon.
# The output is committed, so building the app does not run this.
#
# Usage: scripts/build-raccoon-art.sh [contact-sheet.png]
# With a path, also renders every pose at rest and moved, for review.
set -eu

cd "$(dirname "$0")/.."

swift build --configuration release --product RenderArtwork
bin=$(swift build --configuration release --show-bin-path)

"$bin/RenderArtwork" raccoon Artwork/Raccoon Packaging/Raccoon
echo "Wrote Packaging/Raccoon"

if [ $# -gt 0 ]; then
    "$bin/RenderArtwork" raccoon-contact-sheet Packaging/Raccoon "$1"
    echo "Rendered contact sheet $1"
fi
