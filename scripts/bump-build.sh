#!/bin/bash
# Raises CURRENT_PROJECT_VERSION in project.yml by one. iOS only re-reads NSUbiquitousContainers (the
# "Audiobug" folder in iCloud Drive) when the build number changes, so bump before every device install.
set -euo pipefail
cd "$(dirname "$0")/.."
CUR=$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "?([0-9]+)"?.*/\1/p' project.yml | head -1)
NEXT=$((CUR + 1))
sed -i '' -E "s/^( *CURRENT_PROJECT_VERSION: )\"?$CUR\"?/\1\"$NEXT\"/" project.yml
echo "build $CUR → $NEXT"
