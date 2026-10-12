#!/usr/bin/env bash
# Shared helpers for k3s tag sync.
# Fork tags are read remotely from K3S_FORK_URL, so no kubernetes clone is needed

K3S_FORK_URL="${K3S_FORK_URL:-https://github.com/k3s-io/kubernetes.git}"
UPSTREAM_K8S_URL="${UPSTREAM_K8S_URL:-https://github.com/kubernetes/kubernetes.git}"

# read vX.Y.Z lines on stdin, print the highest
max_semver() {
  grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1
}

# vX.Y.Z -> vX.Y
minor_of() {
  printf '%s\n' "$1" | sed -E 's/^(v[0-9]+\.[0-9]+)\..*/\1/'
}

# vX.Y.Z -> Z
patch_of() {
  printf '%s\n' "$1" | sed -E 's/^v[0-9]+\.[0-9]+\.([0-9]+).*/\1/'
}

# top-level vX.Y.Z-k3sN tags in the fork, cached per script run
# ($$ is the parent shell PID, so the cache survives $(...) subshells)
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

# minors that already carry k3s tags in this fork
tracked_minors() {
  fork_k3s_tags \
    | sed -nE 's/^(v[0-9]+\.[0-9]+)\.[0-9]+-k3s[0-9]+$/\1/p' \
    | sort -uV
}

# vX.Y -> highest k8s patch in the k3s-io/kubernetes fork 
# that has a -k3s tag
latest_fork_k3s_k8s_version() {
  local minor="$1"
  fork_k3s_tags \
    | sed -nE "s/^(${minor//./\\.}\.[0-9]+)-k3s[0-9]+$/\1/p" \
    | sort -uV | max_semver
}

# vX.Y -> highest upstream stable release tag 
# excludes rc, alpha, beta, etc.
latest_upstream_k8s_version() {
  local minor="$1"
  git ls-remote --tags --refs "${UPSTREAM_K8S_URL}" "refs/tags/${minor}.*" \
    | awk '{print $2}' \
    | sed -nE 's|^refs/tags/(v[0-9]+\.[0-9]+\.[0-9]+)$|\1|p' \
    | sort -uV | max_semver
}
