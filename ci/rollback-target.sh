#!/usr/bin/env bash
# Print the commit an environment ran before its current release.
#
#   usage: rollback-target.sh <environment>
#   needs: IMAGE_PREFIX, docker logged in to the registry
#
# Reads the commit from the OCI revision label CI stamps on every image.
# All services of a release share one commit, so the vote image is enough.
set -euo pipefail

env_name="${1:?usage: rollback-target.sh <environment>}"
prefix="${IMAGE_PREFIX:?IMAGE_PREFIX is not set}"
ref="${prefix}/vote:${env_name}-previous"

if ! docker pull --quiet "$ref" > /dev/null 2>&1; then
  echo "::error::${ref} does not exist, so ${env_name} has nothing to roll back to. Pass a version instead." >&2
  exit 1
fi

revision="$(docker inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$ref")"
if ! [[ "$revision" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::${ref} has no usable revision label ('${revision}'). Pass a version instead." >&2
  exit 1
fi

echo "$revision"
