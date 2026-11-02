#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test -d .git || { echo "Initialize this curated repository first." >&2; exit 1; }
git config --local core.hooksPath .githooks
chmod +x .githooks/pre-commit .githooks/pre-push
python3 tools/check_public_release.py --root .
echo "Repository-local hooks enabled. No global git configuration changed."
