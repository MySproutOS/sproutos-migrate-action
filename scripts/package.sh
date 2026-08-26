#!/usr/bin/env bash
#
# Collect the built migrator into one archive.
set -euo pipefail

if ! command -v zip >/dev/null 2>&1; then
  echo "::error::zip is required. On Debian/Ubuntu: apt-get install zip" >&2
  exit 1
fi

if [ ! -d "$DIRECTORY" ]; then
  echo "::error::Nothing at '$DIRECTORY'." >&2
  echo "::error::This must be a *built* migrator, not source: Lambda cannot load a .ts file, and the" >&2
  echo "::error::failure is 'Failed to load the ES module' naming a path, which reads like a missing file." >&2
  exit 1
fi

archive="${RUNNER_TEMP}/sproutos-migration.zip"
rm -f "$archive"

cd "$DIRECTORY"

# Reproducible, and symlinks kept as symlinks.
#
# A pnpm workspace links dependencies rather than copying them. Dereferencing them flattens the
# layout that makes resolution work, and not descending into them ships an archive with no
# dependencies at all — the deploy action learned both of these the hard way.
find . -exec touch -h -t 202001010000.00 {} +
find . -type f -o -type l | LC_ALL=C sort | zip -X -y -q -@ "$archive"

digest=$(shasum -a 256 "$archive" | cut -d' ' -f1)
size=$(wc -c < "$archive" | tr -d ' ')

if [ -z "$digest" ] || [ "$size" -eq 0 ]; then
  echo "::error::Packaging produced nothing." >&2
  exit 1
fi

{
  echo "archive=$archive"
  echo "digest=$digest"
} >> "$GITHUB_OUTPUT"

echo "packaged migrator: $((size / 1024)) KB, sha256:${digest:0:16}…"
