#!/usr/bin/env bash
#
# Downloads the MobileCLIP encoders Cove embeds with.
#
# The weights are ~200 MB and are not in git. Run this once after cloning;
# Xcode compiles what lands in cove/Resources/Models into the app bundle.
#
# Apple publishes Core ML builds of MobileCLIP v1 only. MobileCLIP2-S2 exists as
# PyTorch and ONNX and has the same geometry — 512-wide embeddings, 256px input,
# 77-token CLIP context — so a converted pair drops into
# ~/Library/Application Support/Cove/Models and overrides these without a
# rebuild. Bump `MobileCLIPModelDescriptor.current.id` when you do, or every
# stored vector will be compared against one from the other model.

set -euo pipefail

REPO="apple/coreml-mobileclip"
VARIANT="${1:-s2}"
DEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/cove/Resources/Models"

echo "Fetching mobileclip_${VARIANT} encoders into ${DEST}"
mkdir -p "$DEST"

for tower in image text; do
    package="mobileclip_${VARIANT}_${tower}.mlpackage"
    base="https://huggingface.co/${REPO}/resolve/main/${package}"

    mkdir -p "${DEST}/${package}/Data/com.apple.CoreML/weights"
    curl -fL --progress-bar -o "${DEST}/${package}/Manifest.json" \
        "${base}/Manifest.json"
    curl -fL --progress-bar -o "${DEST}/${package}/Data/com.apple.CoreML/model.mlmodel" \
        "${base}/Data/com.apple.CoreML/model.mlmodel"
    curl -fL --progress-bar -o "${DEST}/${package}/Data/com.apple.CoreML/weights/weight.bin" \
        "${base}/Data/com.apple.CoreML/weights/weight.bin"

    echo "  ${package} done"
done

echo "Encoders installed. Settings will report them as bundled once Cove is rebuilt."
