#!/usr/bin/env bash
# Point an environment at the images of one commit by moving registry tags.
#
#   usage: deploy.sh <environment> <full-commit-sha>
#   needs: IMAGE_PREFIX (e.g. ghcr.io/owner/repo), docker logged in to the registry,
#          the full git history (to compare commits), jq
#   ALLOW_OLDER=true  lets the environment go back to an older commit (rollback).
#
# Without ALLOW_OLDER an environment only moves forward: if it already runs the
# given commit's descendant (a newer main run deployed first), nothing changes.
#
# For each service:  <svc>:<env>          -> <svc>:<env>-previous
#                    <svc>:sha-<commit>   -> <svc>:<env>
# Images are retagged inside the registry (no pull), so the deployed digest is
# exactly the one CI built, scanned and tested.
set -euo pipefail

env_name="${1:?usage: deploy.sh <environment> <commit>}"
version="${2:?usage: deploy.sh <environment> <commit>}"
prefix="${IMAGE_PREFIX:?IMAGE_PREFIX is not set}"
services="${SERVICES:-vote result worker}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

# Digest of a tag, or nothing if the tag does not exist.
digest() {
  { docker buildx imagetools inspect "$1" 2>/dev/null || true; } | awk '/^Digest:/ { print $2; exit }'
}

# Commit an image was built from (the OCI revision label CI stamps), or nothing.
revision() {
  { docker buildx imagetools inspect "$1" --format '{{json .Image}}' 2>/dev/null || true; } \
    | { jq -r '.config.Labels["org.opencontainers.image.revision"] // empty' 2>/dev/null || true; }
}

# 1. Check the whole release exists before moving anything.
for svc in $services; do
  src="${prefix}/${svc}:sha-${version}"
  if [ -z "$(digest "$src")" ]; then
    echo "::error::${src} does not exist. Only commits that passed CI on main can be deployed." >&2
    exit 1
  fi
done

# 2. Never move an environment backwards by accident. Two main runs can finish
#    out of order; the older one must not overwrite what the newer one deployed.
#    Deploys to one environment never overlap (deploy.yml's concurrency group),
#    so nothing can change between this check and the tag move below.
#    All services of a release share one commit, so the vote image is enough.
current_ref="${prefix}/vote:${env_name}"
if [ "${ALLOW_OLDER:-false}" != "true" ] && [ -n "$(digest "$current_ref")" ]; then
  current_commit="$(revision "$current_ref")"
  if ! [[ "$current_commit" =~ ^[0-9a-f]{40}$ ]]; then
    echo "::error::Cannot read which commit ${env_name} runs (no revision label on ${current_ref}). Deploy with allow_older to override." >&2
    exit 1
  fi
  if ! git merge-base --is-ancestor "$current_commit" "$version" 2>/dev/null; then
    echo "::warning::${env_name} already runs ${current_commit:0:12}, which is newer than (or unrelated to) ${version:0:12}. Nothing moved. To go back on purpose, use the rollback workflow."
    echo "### ${env_name} left on ${current_commit:0:12}: ${version:0:12} is not newer" >> "$summary"
    exit 0
  fi
fi

{
  echo "### Deployed ${version:0:12} to ${env_name}"
  echo ""
  echo "| service | digest | previous |"
  echo "|---|---|---|"
} >> "$summary"

# 3. Move the tags.
for svc in $services; do
  src="${prefix}/${svc}:sha-${version}"
  target="${prefix}/${svc}:${env_name}"
  new="$(digest "$src")"
  current="$(digest "$target")"

  if [ "$current" = "$new" ]; then
    echo "${svc}: ${env_name} already runs ${version:0:12}, nothing to do."
    echo "| ${svc} | \`${new:7:12}\` | unchanged |" >> "$summary"
    continue
  fi

  if [ -n "$current" ]; then
    docker buildx imagetools create --tag "${target}-previous" "$target"
  fi
  docker buildx imagetools create --tag "$target" "$src"

  echo "${svc}: ${env_name} -> ${version:0:12} (${new})"
  echo "| ${svc} | \`${new:7:12}\` | \`${current:7:12}\` |" >> "$summary"
done
