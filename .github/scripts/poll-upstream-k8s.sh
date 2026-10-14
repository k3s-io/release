#!/usr/bin/env bash
#
# Detects which tracked minors have a new upstream kubernetes release that has
# not been synced to the fork yet.
#
# For every minor (vX.Y) that already has k3s tags in the fork:
#   1. find the highest k3s-tagged patch in the fork  (fork_latest)
#   2. find the highest stable upstream release       (upstream_latest)
#   3. if upstream is strictly ahead, queue a sync    (fork_latest -> upstream_latest)
#
# Output (written to $GITHUB_OUTPUT, consumed by poll-upstream-k8s.yaml):
#   matrix  JSON list of {new_k8s_version, old_k8s_version}
#   count   number of entries in the matrix
#
# Optional env: K3S_FORK_URL, UPSTREAM_K8S_URL (see lib-k3s-tags.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib-k3s-tags.sh
source "${SCRIPT_DIR}/lib-k3s-tags.sh"


# Start with an empty JSON list and append one entry per minor that needs a sync.
matrix='[]'

while IFS= read -r minor; do
  if [ -z "$minor" ]; then
    continue
  fi

  # Rebase base: the patch the k3s carry commits currently sit on.
  fork_latest="$(latest_fork_k3s_k8s_version "$minor")"

  if [ -z "$fork_latest" ]; then
    continue
  fi

  # Candidate: the newest stable upstream release for this minor.
  upstream_latest="$(latest_upstream_k8s_version "$minor")"

  if [ -z "$upstream_latest" ]; then
    continue
  fi

  # .0 releases are handled manually; only .1 and forward are synced by this automation.
  if [ "$(patch_of "$upstream_latest")" = "0" ]; then
    echo "  ${minor}: skipping ${upstream_latest} (.0 release)"
    continue
  fi

  # Sort both versions and keep the highest. Upstream needs a sync only when it
  # is different from the fork AND it is the higher of the two. This keeps a
  # fork that is somehow ahead of upstream from triggering a downgrade.
  highest="$(printf '%s\n%s\n' "$fork_latest" "$upstream_latest" | sort -V | tail -n1)"

  if [ "$upstream_latest" != "$fork_latest" ] && [ "$highest" = "$upstream_latest" ]; then
    echo "  ${minor}: NEW upstream ${upstream_latest} (fork at ${fork_latest})"

    matrix="$(
      printf '%s' "$matrix" \
        | jq -c \
            --arg new "$upstream_latest" \
            --arg old "$fork_latest" \
            '. + [{new_k8s_version: $new, old_k8s_version: $old}]'
    )"
  else
    echo "  ${minor}: up to date (upstream ${upstream_latest}, fork ${fork_latest})"
  fi
done < <(tracked_minors)


# Hand the matrix and its size to the workflow. The sync job is skipped when count is 0.
count="$(printf '%s' "$matrix" | jq 'length')"

{
  echo "matrix=${matrix}"
  echo "count=${count}"
} >> "$GITHUB_OUTPUT"

echo "found ${count} minor(s) needing sync"
