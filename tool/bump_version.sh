#!/usr/bin/env bash
# Bumps the version for the next release. Only a new version reaches the
# candidate channel, and security-rebuild.yml finds a release's commit by it, so
# bump once per release, in the commit pushed to main.
# Versions count 0.1.0 -> 0.1.1 -> 0.1.2 -> 0.2.0, the same as XBTune.
#   tool/bump_version.sh          # from the repo root; prints old -> new
#   tool/bump_version.sh --check  # only print what the next version would be
set -euo pipefail

line="$(sed -n 's/^version: //p' pubspec.yaml)"
current="${line%%+*}"
build="${line##*+}"
IFS=. read -r major minor patch <<<"$current"
if (( patch >= 2 )); then
  next="${major}.$((minor + 1)).0"
else
  next="${major}.${minor}.$((patch + 1))"
fi

if [[ "${1:-}" == "--check" ]]; then
  echo "$current -> $next"
  exit 0
fi

sed -i "s/^version: .*/version: ${next}+$((build + 1))/" pubspec.yaml
sed -i "s/^const appVersion = '.*';/const appVersion = '${next}';/" lib/src/app_info.dart
echo "$current -> $next"
