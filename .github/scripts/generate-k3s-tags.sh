#!/usr/bin/env bash
#
# Rebases the k3s carry commits onto a new upstream kubernetes release and runs
# the fork's tag.sh to create the k3s tags locally. Nothing is pushed here;
# push-k3s-tags.sh does that.
#
# Steps:
#   1. validate NEW_K8S_VERSION (vX.Y.Z, and not a .0 release)
#   2. derive OLD_K8S_VERSION from the fork's tags when it is not passed
#   3. fetch the new and old upstream tags
#   4. find the latest k3s tag for OLD_K8S_VERSION (v1.36.4-k3s1, -k3s2, ...)
#   5. rebase the carry commits from OLD_K8S_VERSION onto NEW_K8S_VERSION
#   6. run tag.sh in a container with the Go version upstream pins
#   7. save the "git push $REMOTE <tag>" lines to tags-<version>
#
# Required env: NEW_K8S_VERSION
#               NEW_SUFFIX
#               GIT_USER_NAME
#               GIT_USER_EMAIL
#
# Optional env: OLD_K8S_VERSION (derived from fork k3s tags if empty)
#               WORKSPACE       (kubernetes checkout, default PWD)
#               K3S_FORK_URL, UPSTREAM_K8S_URL (see lib-k3s-tags.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib-k3s-tags.sh
source "${SCRIPT_DIR}/lib-k3s-tags.sh"

WORKSPACE="${WORKSPACE:-$PWD}"
TAGS_FILE="${WORKSPACE}/tags-${NEW_K8S_VERSION}"
TAG="${NEW_K8S_VERSION}-${NEW_SUFFIX}"


# ---------------------------------------------------------------------------
# 1. Validate input
# ---------------------------------------------------------------------------

if ! printf '%s' "${NEW_K8S_VERSION}" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "invalid NEW_K8S_VERSION: ${NEW_K8S_VERSION} (expected vX.Y.Z)" >&2
  exit 1
fi

# .0 releases start a new minor and are handled manually.
if [ "$(patch_of "${NEW_K8S_VERSION}")" = "0" ]; then
  echo "${NEW_K8S_VERSION} is a .0 release; only .1 and forward are synced by this automation" >&2
  exit 1
fi

cd "${WORKSPACE}"


# ---------------------------------------------------------------------------
# 2. Resolve OLD_K8S_VERSION (the rebase base)
# ---------------------------------------------------------------------------
#
# OLD_K8S_VERSION is the upstream patch the k3s carry commits currently sit on.
# When not passed, use the highest k3s-tagged patch in the fork for the same minor.
# This only works within one minor; a cross-minor rebase must pass it explicitly.
if [ -z "${OLD_K8S_VERSION:-}" ]; then
  minor="$(minor_of "${NEW_K8S_VERSION}")"
  OLD_K8S_VERSION="$(latest_fork_k3s_k8s_version "${minor}")"

  if [ -z "${OLD_K8S_VERSION}" ]; then
    echo "could not derive OLD_K8S_VERSION for ${minor}" >&2
    exit 1
  fi

  echo "==> derived OLD_K8S_VERSION=${OLD_K8S_VERSION}"
fi

# A tags file means this version was already generated in this workspace.
if [ -f "${TAGS_FILE}" ]; then
  echo "tags file already exists (${TAGS_FILE}); skipping rebase and tag"
  exit 0
fi


# ---------------------------------------------------------------------------
# 3. Git identity and upstream tags
# ---------------------------------------------------------------------------

# The rebase rewrites commits, so git needs a committer identity.
# GPG signing is off because the runner has no signing key.
echo "==> git identity (needed for rebase committer)"
git config user.name  "${GIT_USER_NAME}"
git config user.email "${GIT_USER_EMAIL}"
git config commit.gpgsign false

# Fetch only the two upstream tags the rebase needs, not all upstream tags.
# The old tag usually already exists in the fork, so a failure there is fine.
echo "==> upstream remote + fetch k8s tags"

if ! git remote get-url upstream >/dev/null 2>&1; then
  git remote add upstream "${UPSTREAM_K8S_URL}"
fi

git fetch --no-tags upstream "refs/tags/${NEW_K8S_VERSION}:refs/tags/${NEW_K8S_VERSION}"
git fetch --no-tags upstream "refs/tags/${OLD_K8S_VERSION}:refs/tags/${OLD_K8S_VERSION}" || true


# ---------------------------------------------------------------------------
# 4. Find the latest k3s tag for OLD_K8S_VERSION
# ---------------------------------------------------------------------------
#
# A patch can be released more than once (-k3s1, -k3s2, ...). Walk up from
# -k3s1 and stop at the first missing suffix; the last one found is the
# newest set of carry commits.
echo "==> resolving previous k3s tag for ${OLD_K8S_VERSION}"

PREV_K3S_TAG=""

for i in $(seq 1 9); do
  candidate="${OLD_K8S_VERSION}-k3s${i}"

  if git rev-parse -q --verify "refs/tags/${candidate}" >/dev/null; then
    PREV_K3S_TAG="${candidate}"
  else
    break
  fi
done

if [ -z "${PREV_K3S_TAG}" ]; then
  echo "no previous k3s tag found for ${OLD_K8S_VERSION}" >&2
  exit 1
fi

echo "    previous k3s tag: ${PREV_K3S_TAG}"


# ---------------------------------------------------------------------------
# 5. Rebase the carry commits
# ---------------------------------------------------------------------------

# Start from a clean tree so leftovers from tag.sh or builds can't leak in.
echo "==> cleaning repo"
rm -rf _output
git clean -xfd
git checkout .

# Replay the commits in OLD_K8S_VERSION..PREV_K3S_TAG~1 on top of NEW_K8S_VERSION.
#
# ~1 drops the last commit of the previous release, which is the version-stamp
# commit tag.sh created for it. tag.sh creates a fresh one for the new version.
echo "==> rebase --onto ${NEW_K8S_VERSION} ${OLD_K8S_VERSION} ${PREV_K3S_TAG}~1"
git rebase --onto "${NEW_K8S_VERSION}" "${OLD_K8S_VERSION}" "${PREV_K3S_TAG}~1"


# ---------------------------------------------------------------------------
# 6. Run tag.sh in a container
# ---------------------------------------------------------------------------

# tag.sh builds Go code, so use the exact Go version the new upstream release pins.
echo "==> resolving go version from ${NEW_K8S_VERSION}"

GO_VERSION="$(git show "${NEW_K8S_VERSION}:.go-version" | tr -d '[:space:]')"
GO_IMAGE="golang:${GO_VERSION}-alpine"
DEV_IMAGE="k3s-k8s-tagger:${GO_VERSION}"

echo "    go version: ${GO_VERSION}"

# The golang alpine image plus the tools tag.sh and the kubernetes build need.
echo "==> building tagger image (${DEV_IMAGE})"
docker build -t "${DEV_IMAGE}" - <<EOF
FROM ${GO_IMAGE}
RUN apk add --no-cache bash git make tar gzip curl coreutils rsync alpine-sdk binutils-gold
EOF

# A writable GOPATH/HOME for the container, outside the kubernetes checkout.
#
# The .gitconfig gives tag.sh a committer identity and marks the mounted
# repo as safe (it is owned by the runner user, not the container user).
echo "==> preparing gopath + gitconfig"

GOPATH_DIR="${RUNNER_TEMP:-${WORKSPACE}/.tagger}/gopath"
mkdir -p "${GOPATH_DIR}/.cache"

GITCONFIG_FILE="${GOPATH_DIR}/.gitconfig"

cat > "${GITCONFIG_FILE}" <<EOF
[safe]
	directory = /home/go/src/kubernetes
[user]
	email = ${GIT_USER_EMAIL}
	name = ${GIT_USER_NAME}
[commit]
	gpgsign = false
EOF

# Same layout the old ecm-distro-tools CLI used: the repo is mounted at
# /home/go/src/kubernetes and tag.sh runs as the runner's uid:gid, so files it
# writes stay owned by the runner. Output is kept to extract the push lines.
echo "==> running tag.sh in container -> ${TAG}"

docker run --rm \
  -u "$(id -u):$(id -g)" \
  -v "${GOPATH_DIR}:/home/go:rw" \
  -v "${GITCONFIG_FILE}:/home/go/.gitconfig:rw" \
  -v "${WORKSPACE}:/home/go/src/kubernetes:rw" \
  -e HOME=/home/go \
  -e GOCACHE=/home/go/.cache \
  -w /home/go/src/kubernetes \
  "${DEV_IMAGE}" \
  ./tag.sh "${TAG}" \
  | tee "${WORKSPACE}/tag-output-${NEW_K8S_VERSION}.txt"


# ---------------------------------------------------------------------------
# 7. Save the push commands
# ---------------------------------------------------------------------------
#
# tag.sh prints one "git push $REMOTE <tag>" line per tag it created.
# $REMOTE is literal text, not a variable, hence the single quotes.
echo "==> extracting push commands"

# shellcheck disable=SC2016
grep -F 'git push $REMOTE' "${WORKSPACE}/tag-output-${NEW_K8S_VERSION}.txt" > "${TAGS_FILE}" || true

if [ ! -s "${TAGS_FILE}" ]; then
  echo "failed to extract tag push lines" >&2
  rm -f "${TAGS_FILE}"
  exit 1
fi

echo "wrote $(wc -l < "${TAGS_FILE}") push commands to ${TAGS_FILE}"
cat "${TAGS_FILE}"
