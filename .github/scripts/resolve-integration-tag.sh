#!/usr/bin/env bash
# Resolve rafaelgaspar integration tag: v{upstream-base}-rafaelgaspar.{N} (N starts at 0).
# Usage: resolve-integration-tag.sh <tag-glob> <tag-filter-regex> [base-tag]
#
# Pass [base-tag] from tag-bump (upstream release tag, or v{ver}-{shortsha}
# when tracks:branch). Inferring with `git tag --merged HEAD` is wrong when checkout
# used the triggering github.sha (the pre-rebuild rafaelgaspar tip).
#
# N is global for the Debian upstream version (all v7.0-<sha>-rafaelgaspar.N
# tags share one counter). Hash-based Debian versions are not monotonic, so
# resetting N per sha lets apt/reprepro treat a new hash as older.
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

# Highest rafaelgaspar.N among every sha of this upstream version (7.0, …).
global_integration_n() {
  local ver=$1
  local max=-1 t n
  while IFS= read -r t; do
    [[ -z $t ]] && continue
    n=${t##*.}
    [[ $n =~ ^[0-9]+$ ]] || continue
    if (( n > max )); then
      max=$n
    fi
  done < <(git tag -l "v${ver}-*-rafaelgaspar."*)
  printf '%s\n' "$max"
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
max_n=$(global_integration_n "$deb_upstream")
tag=""
skip_release=false

if (( max_n >= 0 )); then
  while IFS= read -r t; do
    [[ -z $t ]] && continue
    if [[ $(git rev-parse "${t}^{commit}") == "$head_sha" ]]; then
      tag=$t
      skip_release=true
      break
    fi
  done < <(git tag -l "v${deb_upstream}-*-rafaelgaspar.${max_n}")
fi

if [[ $skip_release != true ]]; then
  tag="${base_tag}-rafaelgaspar.$((max_n + 1))"
  skip_release=false
fi

{
  echo "tag=${tag}"
  echo "integration_version=${tag#v}"
  echo "base_tag=${base_tag}"
  echo "package_upstream_version=${deb_upstream}"
  echo "skip_release=${skip_release}"
} >>"$output"
