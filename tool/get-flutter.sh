#!/usr/bin/env bash
# Fetches the Flutter this project builds with, for the snap and CI. The commit
# is checked so a moved tag stops the build.
#   tool/get-flutter.sh <directory>
set -euo pipefail

version=3.47.4
commit=9584c6713b324636289d067944a46fd6b49df14b

dest="$1"
git clone --quiet --depth 1 --branch "$version" \
  https://github.com/flutter/flutter.git "$dest"
actual="$(git -C "$dest" rev-parse HEAD)"
if [[ "$actual" != "$commit" ]]; then
  echo "Flutter $version is at $actual, expected $commit" >&2
  exit 1
fi
