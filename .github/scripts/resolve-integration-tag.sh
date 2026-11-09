#!/usr/bin/env bash
# Resolve rafaelgaspar integration tag: v{upstream-base}-rafaelgaspar.{N} (N starts at 0).
# Usage: resolve-integration-tag.sh <tag-glob> <tag-filter-regex> [base-tag]
#
# Pass [base-tag] from tag-bump (upstream release tag, or v{ver}-{shortsha}
# when tracks:branch). Inferring with `git tag --merged HEAD` is wrong when checkout
# used the triggering github.sha (the pre-rebuild rafaelgaspar tip).
set -euo pipefail

tag_glob="${1:?tag glob}"
tag_filter="${2:?tag filter regex}"
explicit_base="${3:-}"
output="${GITHUB_OUTPUT:-/dev/stdout}"

branch_base_re='^v[0-9]+(\.[0-9]+)*-[0-9a-f]+$'

package_upstream_version() {
  local base=$1
  if [[ $base =~ ^v([0-9]+(\.[0-9]+)*)-[0-9a-f]+$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  printf '%s\n' "${base#v}"
}

if [[ -n $explicit_base ]]; then
  base_tag=$explicit_base
else
  base_tag=$(git tag -l "$tag_glob" --merged HEAD | grep -E "$tag_filter" | sort -V | tail -1 || true)
  # stacks rebuilt onto a branch tip (tracks: branch) do not contain the
  # latest upstream release tag in history; name releases like tag-bump does.
  if [[ -z "${base_tag}" ]] && git remote get-url upstream >/dev/null 2>&1; then
    base_tag=$(
      git ls-remote --tags upstream "refs/tags/${tag_glob}" 2>/dev/null \
        | awk -F/ '{print $3}' \
        | sed 's/\^{}//' \
        | grep -E "$tag_filter" \
        | sort -V \
        | tail -1
    )
  fi
  if [[ -z "${base_tag}" ]]; then
    base_tag=$(git tag -l "$tag_glob" | grep -E "$tag_filter" | sort -V | tail -1 || true)
  fi
fi
[[ -n "${base_tag}" ]] || { echo "No upstream base tag found on branch" >&2; exit 1; }
if [[ -n $explicit_base ]] && echo "${base_tag}" | grep -Eq "${branch_base_re}"; then
  :
elif ! echo "${base_tag}" | grep -Eq "${tag_filter}"; then
  echo "error: base tag ${base_tag} does not match ${tag_filter}" >&2
  exit 1
fi

deb_upstream=$(package_upstream_version "${base_tag}")

head_sha=$(git rev-parse HEAD)

build=0
prefix="${base_tag}-rafaelgaspar.${build}"
while git rev-parse "${prefix}" >/dev/null 2>&1; do
  existing=$(git rev-parse "${prefix}^{commit}")
  if [[ "${existing}" == "${head_sha}" ]]; then
    {
      echo "tag=${prefix}"
      echo "integration_version=${prefix#v}"
      echo "base_tag=${base_tag}"
      echo "package_upstream_version=${deb_upstream}"
      echo "skip_release=true"
    } >>"$output"
    exit 0
  fi
  build=$((build + 1))
  prefix="${base_tag}-rafaelgaspar.${build}"
done

{
  echo "tag=${prefix}"
  echo "integration_version=${prefix#v}"
  echo "base_tag=${base_tag}"
  echo "package_upstream_version=${deb_upstream}"
  echo "skip_release=false"
} >>"$output"
