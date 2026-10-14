#!/usr/bin/env bash
#
# Shared helpers for the k3s tag sync.
#
# This file is sourced, never executed, by:
#   - poll-upstream-k8s.sh  (decides which minors need a sync)
#   - generate-k3s-tags.sh  (derives OLD_K8S_VERSION when it is not passed)
#
# Fork tags are read remotely with `git ls-remote` from K3S_FORK_URL,
# so none of these helpers need a local kubernetes clone.

# Fork that receives the k3s tags (k3s-io/kubernetes in production).
K3S_FORK_URL="${K3S_FORK_URL:-https://github.com/k3s-io/kubernetes.git}"

# Upstream kubernetes, the source of new releases.
UPSTREAM_K8S_URL="${UPSTREAM_K8S_URL:-https://github.com/kubernetes/kubernetes.git}"


# ---------------------------------------------------------------------------
# Version string helpers
# ---------------------------------------------------------------------------

# Reads vX.Y.Z lines on stdin and prints the highest one.
# Lines that are not plain vX.Y.Z (rc, alpha, beta, -k3sN, ...) are dropped.
max_semver() {
  grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V \
    | tail -n1
}

# vX.Y.Z -> vX.Y
#   e.g. v1.36.5 -> v1.36
minor_of() {
  printf '%s\n' "$1" \
    | sed -E 's/^(v[0-9]+\.[0-9]+)\..*/\1/'
}

# vX.Y.Z -> Z
#   e.g. v1.36.5 -> 5
patch_of() {
  printf '%s\n' "$1" \
    | sed -E 's/^v[0-9]+\.[0-9]+\.([0-9]+).*/\1/'
}


# ---------------------------------------------------------------------------
# Fork (k3s-io/kubernetes) helpers
# ---------------------------------------------------------------------------

# Prints every top-level vX.Y.Z-k3sN tag in the fork, one per line.
#
# Staging tags (staging/src/k8s.io/<module>/vX.Y.Z-k3sN) are ignored here,
# since the top-level tag is enough to know which versions were released.
#
# The fork has thousands of tags, so the result is cached in a temp file for
# the duration of one script run. $$ is the PID of the top-level shell, even
# inside $(...) subshells, so every call in the same run reuses the cache.
fork_k3s_tags() {
  local cache="${TMPDIR:-/tmp}/k3s-fork-tags.$$"

  if [ ! -s "${cache}" ]; then
    git ls-remote --tags --refs "${K3S_FORK_URL}" \
      | awk '{print $2}' \
      | sed -nE 's|^refs/tags/(v[0-9]+\.[0-9]+\.[0-9]+-k3s[0-9]+)$|\1|p' \
      > "${cache}"
  fi

  cat "${cache}"
}

# Prints the minors (vX.Y) that already have at least one k3s tag in the fork.
#
# This is the list of minors the poller tracks. A brand-new minor only shows
# up here after its first k3s tag exists, which is why .0 is a manual step.
tracked_minors() {
  fork_k3s_tags \
    | sed -nE 's/^(v[0-9]+\.[0-9]+)\.[0-9]+-k3s[0-9]+$/\1/p' \
    | sort -uV
}

# vX.Y -> highest k8s patch (vX.Y.Z) in the fork that has a -k3sN tag.
#
# This is the version the k3s carry commits currently sit on, which makes it
# the OLD_K8S_VERSION (rebase base) for the next sync.
#   e.g. fork has v1.36.4-k3s1 and v1.36.3-k3s1 -> prints v1.36.4
latest_fork_k3s_k8s_version() {
  local minor="$1"

  # escape the dots in vX.Y so they match literally in the regex
  local minor_re="${minor//./\\.}"

  fork_k3s_tags \
    | sed -nE "s/^(${minor_re}\.[0-9]+)-k3s[0-9]+$/\1/p" \
    | sort -uV \
    | max_semver
}


# ---------------------------------------------------------------------------
# Upstream (kubernetes/kubernetes) helpers
# ---------------------------------------------------------------------------

# vX.Y -> highest stable upstream release (vX.Y.Z) for that minor.
#
# Pre-releases (rc, alpha, beta) are excluded by the regex and by max_semver.
#   e.g. upstream has v1.36.5 and v1.36.6-rc.0 -> prints v1.36.5
latest_upstream_k8s_version() {
  local minor="$1"

  git ls-remote --tags --refs "${UPSTREAM_K8S_URL}" "refs/tags/${minor}.*" \
    | awk '{print $2}' \
    | sed -nE 's|^refs/tags/(v[0-9]+\.[0-9]+\.[0-9]+)$|\1|p' \
    | sort -uV \
    | max_semver
}
