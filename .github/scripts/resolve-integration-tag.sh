#!/usr/bin/env bash
# Resolve rafaelgaspar integration tag: v{upstream-base}-rafaelgaspar.{N} (N starts at 0).
# Usage: resolve-integration-tag.sh <tag-glob> <tag-filter-regex>
set -euo pipefail

tag_glob="${1:?tag glob}"
tag_filter="${2:?tag filter regex}"
output="${GITHUB_OUTPUT:-/dev/stdout}"

base_tag=$(git tag -l "$tag_glob" --merged HEAD | grep -E "$tag_filter" | sort -V | tail -1)
[[ -n "${base_tag}" ]] || { echo "No upstream base tag found on branch" >&2; exit 1; }

build=0
prefix="${base_tag}-rafaelgaspar.${build}"
while git rev-parse "${prefix}" >/dev/null 2>&1; do
  existing=$(git rev-parse "${prefix}")
  if [[ "${existing}" == "${GITHUB_SHA:-}" ]]; then
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
