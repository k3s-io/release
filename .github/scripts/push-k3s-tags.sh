#!/usr/bin/env bash
set -euo pipefail

# Required env: NEW_K8S_VERSION
# Optional:     WORKSPACE (default PWD), DRY_RUN (default true), GH_TOKEN (real push)

WORKSPACE="${WORKSPACE:-$PWD}"
DRY_RUN="${DRY_RUN:-true}"
TAGS_FILE="${WORKSPACE}/tags-${NEW_K8S_VERSION}"

cd "${WORKSPACE}"
[ -s "${TAGS_FILE}" ] || { echo "tags file not found or empty: ${TAGS_FILE}" >&2; exit 1; }

if [ "${DRY_RUN}" != "true" ]; then
  : "${GH_TOKEN:?GH_TOKEN required for non-dry-run push}"
  # header set via git config (not echoed), persist-credentials:false on checkout
  AUTH="AUTHORIZATION: basic $(printf 'x-access-token:%s' "${GH_TOKEN}" | base64 | tr -d '\n')"
  git config --local "http.https://github.com/.extraheader" "${AUTH}"
fi

total=$(wc -l < "${TAGS_FILE}")
i=0
while IFS= read -r line; do
  [ -n "${line}" ] || continue
  i=$((i+1))
  tag=$(printf '%s\n' "${line}" | awk '{print $4}')
  [ -n "${tag}" ] || { echo "skipping malformed line: ${line}" >&2; continue; }
  echo "pushing tag ${i}/${total}: ${tag}"
  if [ "${DRY_RUN}" = "true" ]; then
    echo "  dry run, skipping ${tag}"
    continue
  fi
  git push origin "+refs/tags/${tag}:refs/tags/${tag}"
done < "${TAGS_FILE}"

if [ "${DRY_RUN}" != "true" ]; then
  git config --local --unset "http.https://github.com/.extraheader" || true
fi
