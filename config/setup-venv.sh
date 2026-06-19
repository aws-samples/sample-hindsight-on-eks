#!/bin/bash
# Creates a virtual environment and installs dependencies for apply.py.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -d "venv" ]; then
  python3 -m venv venv
  echo "Created virtual environment at config/venv/"
fi

source venv/bin/activate
pip install -q --upgrade pip
pip install -q -r requirements.txt
echo "Dependencies installed. Run: source config/venv/bin/activate"
