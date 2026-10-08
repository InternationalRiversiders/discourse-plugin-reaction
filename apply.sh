#!/usr/bin/env bash
set -euo pipefail
patch_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
discourse_root="${1:?Usage: bash apply.sh /path/to/discourse}"
cd "$discourse_root"
patch_file="$patch_dir/patches/reaction-counts.patch"
if git apply --reverse --check "$patch_file" 2>/dev/null; then
  echo 'Riverside reaction counts patch is already applied.'
  exit 0
fi
git apply --check "$patch_file"
git apply "$patch_file"
echo 'Riverside reaction counts patch applied.'
