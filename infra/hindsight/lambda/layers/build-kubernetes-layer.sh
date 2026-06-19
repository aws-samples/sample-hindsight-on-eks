#!/bin/bash
# Builds a Lambda layer zip with the kubernetes Python package
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/../../.build/kubernetes-layer"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/python"

pip3 install --target "$BUILD_DIR/python" --platform manylinux2014_x86_64 \
  --implementation cp --python-version 3.12 --only-binary=:all: \
  "kubernetes>=28.0.0" 2>/dev/null || \
pip3 install --target "$BUILD_DIR/python" "kubernetes>=28.0.0"

cd "$BUILD_DIR"
zip -r "$SCRIPT_DIR/../../.build/kubernetes-layer.zip" python/ -x "*.pyc" "*/__pycache__/*"

echo "Layer built: infra/hindsight/.build/kubernetes-layer.zip"
