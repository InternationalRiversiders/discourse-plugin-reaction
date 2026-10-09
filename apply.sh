#!/usr/bin/env bash
set -euo pipefail
patch_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
discourse_root="${1:?Usage: bash apply.sh /path/to/discourse}"
cd "$discourse_root"
pending=()
for patch_file in "$patch_dir"/patches/*.patch; do
  if git apply --reverse --check "$patch_file" 2>/dev/null; then
    echo "Already applied: $(basename "$patch_file")"
  else
    pending+=("$patch_file")
  fi
done
if ((${#pending[@]})); then
  # Check the complete change before modifying any file.
  git apply --check "${pending[@]}"
  git apply "${pending[@]}"
  echo "Applied ${#pending[@]} Riverside patch(es)."
fi
