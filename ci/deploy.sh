#!/usr/bin/env bash
# Point an environment at the images of one commit by moving registry tags.
#
#   usage: deploy.sh <environment> <full-commit-sha>
#   needs: IMAGE_PREFIX (e.g. ghcr.io/owner/repo), docker logged in to the registry
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

# 1. Check the whole release exists before moving anything.
for svc in $services; do
  src="${prefix}/${svc}:sha-${version}"
  if [ -z "$(digest "$src")" ]; then
    echo "::error::${src} does not exist. Only commits that passed CI on main can be deployed." >&2
    exit 1
  fi
done

{
  echo "### Deployed ${version:0:12} to ${env_name}"
  echo ""
  echo "| service | digest | previous |"
  echo "|---|---|---|"
} >> "$summary"

# 2. Move the tags.
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
