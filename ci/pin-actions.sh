#! /usr/bin/env bash
# Replace every `uses: owner/repo@vX.Y.Z` in the workflows with the commit SHA
# that tag points to, keeping the version as a comment:
#
#   uses: actions/checkout@v5.0.0   ->   uses: actions/checkout@<40-char sha> # v5.0.0
#
# Tags can be moved; a SHA cannot. Dependabot keeps both the SHA and the comment
# up to date afterwards. Needs only git and network access. Safe to run again.
set -euo pipefail

cd "$(dirname "$0")/.."
workflows=.github/workflows

mapfile -t refs < <(
  grep -rhoE 'uses:[[:space:]]*[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@v[0-9][^[:space:]#]*' "$workflows" \
    | sed -E 's/^uses:[[:space:]]*//' | sort -u
)

if [ "${#refs[@]}" -eq 0 ]; then
  echo "Nothing to pin."
  exit 0
fi

for ref in "${refs[@]}"; do
  action="${ref%@*}"
  tag="${ref#*@}"
  repo="$(cut -d/ -f1-2 <<< "$action")"

  out="$(git ls-remote --tags "https://github.com/${repo}.git" "refs/tags/${tag}" "refs/tags/${tag}^{}")"
  # An annotated tag lists the tag object and the commit (^{}); we want the commit.
  sha="$(awk '/\^\{\}$/ { print $1 }' <<< "$out")"
  [ -n "$sha" ] || sha="$(awk 'NR == 1 { print $1 }' <<< "$out")"
  if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "error: tag ${tag} not found in ${repo}" >&2
    exit 1
  fi

  pattern="uses:([[:space:]]*)${action//./\\.}@${tag//./\\.}([[:space:]]|$)"
  grep -rlE "$pattern" "$workflows" | while read -r file; do
    # "~" as delimiter: the pattern contains "|" and the replacement contains "#".
    sed -i -E "s~${pattern}~uses:\1${action}@${sha} # ${tag}\2~" "$file"
  done
  echo "${action}@${tag} -> ${sha}"
done
