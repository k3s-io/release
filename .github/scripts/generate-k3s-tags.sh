#!/usr/bin/env bash
set -euo pipefail

# Required envs:  NEW_K8S_VERSION 
#                 NEW_SUFFIX 
#                 GIT_USER_NAME 
#                 GIT_USER_EMAIL
#
# Optional:       OLD_K8S_VERSION (derived from fork k3s tags if empty)
#                 WORKSPACE (default PWD)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib-k3s-tags.sh
source "${SCRIPT_DIR}/lib-k3s-tags.sh"

WORKSPACE="${WORKSPACE:-$PWD}"
TAGS_FILE="${WORKSPACE}/tags-${NEW_K8S_VERSION}"
TAG="${NEW_K8S_VERSION}-${NEW_SUFFIX}"

if ! printf '%s' "${NEW_K8S_VERSION}" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "invalid NEW_K8S_VERSION: ${NEW_K8S_VERSION} (expected vX.Y.Z)" >&2
  exit 1
fi
if [ "$(patch_of "${NEW_K8S_VERSION}")" = "0" ]; then
  echo "${NEW_K8S_VERSION} is a .0 release; only .1 and forward are synced by this automation" >&2
  exit 1
fi

cd "${WORKSPACE}"

if [ -z "${OLD_K8S_VERSION:-}" ]; then
  minor="$(minor_of "${NEW_K8S_VERSION}")"
  OLD_K8S_VERSION="$(latest_fork_k3s_k8s_version "${minor}")"
  [ -n "${OLD_K8S_VERSION}" ] || { echo "could not derive OLD_K8S_VERSION for ${minor}" >&2; exit 1; }
  echo "==> derived OLD_K8S_VERSION=${OLD_K8S_VERSION}"
fi

if [ -f "${TAGS_FILE}" ]; then
  echo "tags file already exists (${TAGS_FILE}); skipping rebase and tag"
  exit 0
fi

echo "==> git identity (needed for rebase committer)"
git config user.name  "${GIT_USER_NAME}"
git config user.email "${GIT_USER_EMAIL}"
git config commit.gpgsign false

echo "==> upstream remote + fetch k8s tags"
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "${UPSTREAM_K8S_URL}"
git fetch --no-tags upstream "refs/tags/${NEW_K8S_VERSION}:refs/tags/${NEW_K8S_VERSION}"
git fetch --no-tags upstream "refs/tags/${OLD_K8S_VERSION}:refs/tags/${OLD_K8S_VERSION}" || true

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
[ -n "${PREV_K3S_TAG}" ] || { echo "no previous k3s tag found for ${OLD_K8S_VERSION}" >&2; exit 1; }
echo "    previous k3s tag: ${PREV_K3S_TAG}"

echo "==> cleaning repo"
rm -rf _output
git clean -xfd
git checkout .

echo "==> rebase --onto ${NEW_K8S_VERSION} ${OLD_K8S_VERSION} ${PREV_K3S_TAG}~1"
git rebase --onto "${NEW_K8S_VERSION}" "${OLD_K8S_VERSION}" "${PREV_K3S_TAG}~1"

echo "==> resolving go version from ${NEW_K8S_VERSION}"
GO_VERSION="$(git show "${NEW_K8S_VERSION}:.go-version" | tr -d '[:space:]')"
GO_IMAGE="golang:${GO_VERSION}-alpine"
DEV_IMAGE="k3s-k8s-tagger:${GO_VERSION}"
echo "    go version: ${GO_VERSION}"

echo "==> building tagger image (${DEV_IMAGE})"
docker build -t "${DEV_IMAGE}" - <<EOF
FROM ${GO_IMAGE}
RUN apk add --no-cache bash git make tar gzip curl coreutils rsync alpine-sdk binutils-gold
EOF

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
  ./tag.sh "${TAG}" | tee "${WORKSPACE}/tag-output-${NEW_K8S_VERSION}.txt"

echo "==> extracting push commands"
grep -F 'git push $REMOTE' "${WORKSPACE}/tag-output-${NEW_K8S_VERSION}.txt" > "${TAGS_FILE}" || true
if [ ! -s "${TAGS_FILE}" ]; then
  echo "failed to extract tag push lines" >&2
  rm -f "${TAGS_FILE}"
  exit 1
fi
echo "wrote $(wc -l < "${TAGS_FILE}") push commands to ${TAGS_FILE}"
cat "${TAGS_FILE}"
