#!/usr/bin/env bash
# Resolve rafaelgaspar integration tag: v{upstream-base}-rafaelgaspar.{N} (N starts at 0).
# Usage: resolve-integration-tag.sh <tag-glob> <tag-filter-regex> [base-tag]
#
# Pass [base-tag] from tag-bump (the upstream tag that was just restacked).
# Inferring it with `git tag --merged HEAD` is wrong when checkout used the
# triggering github.sha (the pre-rebuild rafaelgaspar tip).
set -euo pipefail

tag_glob="${1:?tag glob}"
tag_filter="${2:?tag filter regex}"
explicit_base="${3:-}"
output="${GITHUB_OUTPUT:-/dev/stdout}"

if [[ -n $explicit_base ]]; then
  base_tag=$explicit_base
else
  base_tag=$(git tag -l "$tag_glob" --merged HEAD | grep -E "$tag_filter" | sort -V | tail -1)
fi
[[ -n "${base_tag}" ]] || { echo "No upstream base tag found on branch" >&2; exit 1; }
if ! echo "${base_tag}" | grep -Eq "${tag_filter}"; then
  echo "error: base tag ${base_tag} does not match ${tag_filter}" >&2
  exit 1
fi

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
  echo "skip_release=false"
} >>"$output"
