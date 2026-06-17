#!/usr/bin/env bash
# Bump the skill version in every place it lives, so a release can never ship
# with the 5 version fields out of sync. Run from the repo root.
#
#   ./scripts/bump-version.sh 0.2.0
#
# Then review `git diff`, update CHANGELOG.md, commit, tag, and push:
#   git commit -am "release: v0.2.0"
#   git tag v0.2.0 && git push && git push --tags
#   gh release create v0.2.0 --generate-notes

set -euo pipefail

NEW="${1:?usage: ./scripts/bump-version.sh X.Y.Z}"
if ! [[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: '$NEW' is not semver (X.Y.Z)" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SKILL_MD="skills/clickhouse-debug/SKILL.md"
SKILL_META="skills/clickhouse-debug/metadata.json"
PLUGIN=".claude-plugin/plugin.json"
MARKET=".claude-plugin/marketplace.json"

for f in "$SKILL_MD" "$SKILL_META" "$PLUGIN" "$MARKET"; do
  [ -f "$f" ] || { echo "error: missing $f (run from repo root)" >&2; exit 1; }
done

# JSON files: replace every "version": "..." occurrence. In this repo all such
# fields move together (skill metadata, plugin, marketplace metadata + entry).
perl -i -pe 's/("version"\s*:\s*")[^"]*(")/${1}'"$NEW"'${2}/g' \
  "$SKILL_META" "$PLUGIN" "$MARKET"

# SKILL.md YAML frontmatter: the indented `  version: "..."` under metadata.
perl -i -pe 's/^(\s*version:\s*")[^"]*(")/${1}'"$NEW"'${2}/' "$SKILL_MD"

# Refresh the human-readable date in metadata.json (e.g. "June 2026").
TODAY="$(date '+%B %Y')"
perl -i -pe 's/("date"\s*:\s*")[^"]*(")/${1}'"$TODAY"'${2}/' "$SKILL_META"

echo "Bumped to v$NEW (date: $TODAY). Changed lines:"
grep -rn '"version"\|"date"' "$SKILL_META" "$PLUGIN" "$MARKET"
grep -n 'version:' "$SKILL_MD"

echo
echo "Next: edit CHANGELOG.md, then:"
echo "  git commit -am \"release: v$NEW\""
echo "  git tag v$NEW && git push && git push --tags"
echo "  gh release create v$NEW --generate-notes"
