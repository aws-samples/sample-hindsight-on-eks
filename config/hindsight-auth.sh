#!/bin/bash
# hindsight-auth.sh — Fetches your Hindsight API key via Cognito PKCE flow.
# Run daily. Caches key to ~/.hindsight/token for use by plugins and scripts.
#
# Dependencies: python3 (pre-installed on macOS)
# No pip packages required.
set -e

mkdir -p "$HOME/.hindsight"

exec python3 "$(dirname "$0")/hindsight-auth.py"
