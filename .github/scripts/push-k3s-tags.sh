#!/usr/bin/env bash
#
# Pushes the k3s tags created by generate-k3s-tags.sh to the fork (origin).
#
# Input is the tags file written by generate, one line per tag, in the format
# tag.sh prints them (the literal string $REMOTE is part of the line):
#   git push $REMOTE staging/src/k8s.io/api/v1.36.5-k3s1
#   git push $REMOTE v1.36.5-k3s1
#
# Required env: NEW_K8S_VERSION
#
# Optional env: WORKSPACE (kubernetes checkout, default PWD)
#               DRY_RUN   (default true, only prints the tags)
#               GH_TOKEN  (required when DRY_RUN is not true)

set -euo pipefail

WORKSPACE="${WORKSPACE:-$PWD}"
DRY_RUN="${DRY_RUN:-true}"
TAGS_FILE="${WORKSPACE}/tags-${NEW_K8S_VERSION}"

cd "${WORKSPACE}"

if [ ! -s "${TAGS_FILE}" ]; then
  echo "tags file not found or empty: ${TAGS_FILE}" >&2
  exit 1
fi


# ---------------------------------------------------------------------------
# Auth (real push only)
# ---------------------------------------------------------------------------
#
# The checkout runs with persist-credentials: false, so origin has no
# credentials. Set them here as an HTTP header in the local git config,
# which keeps the token out of the command line and the logs.
if [ "${DRY_RUN}" != "true" ]; then
  : "${GH_TOKEN:?GH_TOKEN required for non-dry-run push}"

  AUTH="AUTHORIZATION: basic $(printf 'x-access-token:%s' "${GH_TOKEN}" | base64 | tr -d '\n')"
  git config --local "http.https://github.com/.extraheader" "${AUTH}"
fi


# ---------------------------------------------------------------------------
# Push each tag
# ---------------------------------------------------------------------------
#
# The "+" in the refspec force-pushes, so re-running the sync for the same
# version overwrites tags left behind by a failed or partial run.
total=$(wc -l < "${TAGS_FILE}")
i=0

while IFS= read -r line; do
  if [ -z "${line}" ]; then
    continue
  fi

  i=$((i+1))

  # field 4 is the tag name: git(1) push(2) $REMOTE(3) <tag>(4)
  tag=$(printf '%s\n' "${line}" | awk '{print $4}')

  if [ -z "${tag}" ]; then
    echo "skipping malformed line: ${line}" >&2
    continue
  fi

  echo "pushing tag ${i}/${total}: ${tag}"

  if [ "${DRY_RUN}" = "true" ]; then
    echo "  dry run, skipping ${tag}"
    continue
  fi

  git push origin "+refs/tags/${tag}:refs/tags/${tag}"
done < "${TAGS_FILE}"


# Remove the auth header so later steps in the job never inherit it.
if [ "${DRY_RUN}" != "true" ]; then
  git config --local --unset "http.https://github.com/.extraheader" || true
fi
