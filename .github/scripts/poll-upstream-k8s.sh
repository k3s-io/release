#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-k3s-tags.sh
source "${SCRIPT_DIR}/lib-k3s-tags.sh"

# Emit a matrix of {new_k8s_version, old_k8s_version} for minors where upstream
# kubernetes/kubernetes has a release ahead of our latest k3s-tagged version.
matrix='[]'
while IFS= read -r minor; do
  [ -n "$minor" ] || continue
  fork_latest="$(latest_fork_k3s_k8s_version "$minor")"
  [ -n "$fork_latest" ] || continue
  upstream_latest="$(latest_upstream_k8s_version "$minor")"
  [ -n "$upstream_latest" ] || continue

  # .0 releases are handled manually; only .1 and forward are synced by this automation
  if [ "$(patch_of "$upstream_latest")" = "0" ]; then
    echo "  ${minor}: skipping ${upstream_latest} (.0 release)"
    continue
  fi

  highest="$(printf '%s\n%s\n' "$fork_latest" "$upstream_latest" | sort -V | tail -n1)"
  if [ "$upstream_latest" != "$fork_latest" ] && [ "$highest" = "$upstream_latest" ]; then
    echo "  ${minor}: NEW upstream ${upstream_latest} (fork at ${fork_latest})"
    matrix="$(printf '%s' "$matrix" | jq -c \
      --arg new "$upstream_latest" --arg old "$fork_latest" \
      '. + [{new_k8s_version:$new, old_k8s_version:$old}]')"
  else
    echo "  ${minor}: up to date (upstream ${upstream_latest}, fork ${fork_latest})"
  fi
done < <(tracked_minors)

count="$(printf '%s' "$matrix" | jq 'length')"
{
  echo "matrix=${matrix}"
  echo "count=${count}"
} >> "$GITHUB_OUTPUT"
echo "found ${count} minor(s) needing sync"
