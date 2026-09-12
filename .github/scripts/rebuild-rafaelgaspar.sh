#!/usr/bin/env bash
# Rebuild stacked feat/* branches on upstream release tag T and point rafaelgaspar at the stack tip.
# Stack order is derived from commit depth on the upstream tag (linear stack).
# See .cursor/skills/rafaelgaspar-fork/SKILL.md
set -euo pipefail

INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-rafaelgaspar}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
ORIGIN_REMOTE="${ORIGIN_REMOTE:-origin}"
ROOT_FEAT="${ROOT_FEAT:-feat/rafaelgaspar}"
UPSTREAM_TAG_PATTERN="${UPSTREAM_TAG_PATTERN:-^v[0-9]+\\.[0-9]+\\.[0-9]+$}"

UPSTREAM_TAG=""
PUSH=false
DRY_RUN=false
SQUASH=false

usage() {
  cat <<'EOF'
Usage: rebuild-rafaelgaspar.sh [options] <upstream-tag>

Rebuild the linear feat/* stack on upstream tag T and reset rafaelgaspar to the stack tip.

Options:
  --push            Push rebased feat/* branches and rafaelgaspar (--force-with-lease)
  --squash          Squash each layer to one commit and fix automation titles
  --dry-run         Discover and validate the stack only; do not rebase or push
  -h, --help        Show this help
EOF
}

log() {
  printf '==> %s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

ref_tip() {
  git rev-parse "$1^{commit}"
}

feat_remote() {
  printf '%s/%s\n' "$ORIGIN_REMOTE" "$1"
}

list_feat_branches() {
  git for-each-ref "refs/remotes/${ORIGIN_REMOTE}/feat" --format='%(refname:short)' \
    | sed "s|^${ORIGIN_REMOTE}/||" \
    | sort -u
}

discover_stack() {
  local branch count order i

  mapfile -t FEAT_BRANCHES < <(list_feat_branches)
  ((${#FEAT_BRANCHES[@]} > 0)) || die "no origin/feat/* branches found"

  mapfile -t STACK < <(
    for branch in "${FEAT_BRANCHES[@]}"; do
      count=$(git rev-list --count "${UPSTREAM_SHA}..$(ref_tip "$(feat_remote "$branch")")")
      if [[ $branch == "$ROOT_FEAT" ]]; then
        order=$((count * 2))
      else
        order=$((count * 2 + 1))
      fi
      printf '%d\t%s\n' "$order" "$branch"
    done | sort -n | cut -f2-
  )

  [[ ${STACK[0]} == "$ROOT_FEAT" ]] \
    || die "${ROOT_FEAT} must lead the stack closest to ${UPSTREAM_TAG}; got ${STACK[0]}"

  declare -g -A STACK_PARENT=()
  for i in $(seq 1 $((${#STACK[@]} - 1))); do
    STACK_PARENT[${STACK[$i]}]=${STACK[$((i - 1))]}
  done

  STACK_TIP=${STACK[$((${#STACK[@]} - 1))]}
}

validate_integration_pointer() {
  local integration_ref=$1
  local tip_ref=$2
  local integration_tip expected

  integration_tip=$(ref_tip "$integration_ref")
  expected=$(ref_tip "$tip_ref")
  [[ $integration_tip == "$expected" ]] \
    || die "${integration_ref} (${integration_tip}) must match stack tip ${tip_ref} (${expected})"
}

validate_stack_link() {
  local branch=$1
  local parent_ref=$2
  local mb parent_tip

  parent_tip=$(ref_tip "$parent_ref")
  mb=$(git merge-base "$(ref_tip "$branch")" "$parent_tip")
  [[ $mb == "$parent_tip" ]] \
    || die "${branch} is not based on ${parent_ref}; merge-base is ${mb}"
}

LAYER_SUBJECT_SKIP_RE='^(Merge |chore\(ci\): (drop upstream|keep upstream)|fix\(rebuild\): )'

layer_tree_ref() {
  printf '%s/%s\n' "$ORIGIN_REMOTE" "$1"
}

layer_history_ref() {
  local branch=$1
  if git show-ref --verify --quiet "refs/remotes/archive/${branch}"; then
    printf 'archive/%s\n' "$branch"
  else
    printf '%s/%s\n' "$ORIGIN_REMOTE" "$branch"
  fi
}

pick_layer_subject() {
  local branch=$1
  local source_ref=$2
  local parent_ref=$3
  local subject="" feat_key

  if [[ $branch == "$ROOT_FEAT" ]]; then
    subject=$(
      {
        git log --format=%s --all
        git log -g --all --format=%s
      } | grep -E '^feat\(rafaelgaspar\):' | head -1 || true
    )
    [[ -z $subject ]] && subject=$(
      {
        git log --format=%s --all
        git log -g --all --format=%s
      } | grep -E '^feat: fork infra' | head -1 || true
    )
  elif [[ $branch == feat/* ]]; then
    feat_key=${branch#feat/}
    subject=$(
      {
        git log --format=%s --all
        git log -g --all --format=%s
      } | grep -E "^feat\\(${feat_key}\\):" | head -1 || true
    )
  fi
  if [[ -z $subject ]] && git merge-base --is-ancestor "$parent_ref" "$source_ref" 2>/dev/null; then
    subject=$(git log --reverse --format=%s "${parent_ref}..${source_ref}" \
      | grep -Ev "$LAYER_SUBJECT_SKIP_RE" | tail -1 || true)
  fi
  if [[ -z $subject ]]; then
    subject=$(git log --format=%s "$source_ref" \
      | grep -Ev "$LAYER_SUBJECT_SKIP_RE" | head -1 || true)
  fi
  [[ -n $subject ]] || subject=$(git log -1 --format=%s "$source_ref")
  printf '%s\n' "$subject"
}

layer_title_needs_fix() {
  local subject=$1
  [[ $subject =~ $LAYER_SUBJECT_SKIP_RE ]] && return 0
  [[ $subject == Merge* ]] && return 0
  return 1
}

squash_layer() {
  local branch=$1
  local parent_ref=$2
  local source_ref=$3
  local count subject msg_file

  count=$(git rev-list --count "${parent_ref}..HEAD")
  (( count <= 1 )) && return 0

  subject=$(pick_layer_subject "$branch" "$source_ref" "$parent_ref")
  msg_file=$(mktemp)
  {
    printf '%s\n\n' "$subject"
    printf 'Squashed %d commits on %s:\n' "$count" "$branch"
    git log --reverse --format='- %s' "${parent_ref}..HEAD"
  } >"$msg_file"
  git reset --soft "$parent_ref"
  git commit -F "$msg_file"
  rm -f "$msg_file"
}

install_canonical_script() {
  local script_path=${CANONICAL_REBUILD_SCRIPT:-}
  [[ -n $script_path && -f $script_path ]] || return 0
  cp "$script_path" .github/scripts/rebuild-rafaelgaspar.sh
  chmod +x .github/scripts/rebuild-rafaelgaspar.sh
  git add .github/scripts/rebuild-rafaelgaspar.sh
  if ! git diff --cached --quiet; then
    git commit --amend --no-edit
  fi
}

finalize_layer_commit() {
  local branch=$1
  local parent_ref=$2
  local source_ref=$3
  local count current desired

  count=$(git rev-list --count "${parent_ref}..HEAD")
  if $SQUASH && (( count > 1 )); then
    log "squash ${branch} onto ${parent_ref}"
    squash_layer "$branch" "$parent_ref" "$source_ref"
  fi

  if [[ $branch == "$ROOT_FEAT" ]]; then
    install_canonical_script
  fi

  desired=$(pick_layer_subject "$branch" "$source_ref" "$parent_ref")
  current=$(git log -1 --format=%s)
  if [[ $current != "$desired" ]]; then
    git commit --amend -m "$desired"
  fi
}

# Child layers carry feature diffs only; fork CI layout comes from the parent tip.
apply_child_layer_tree() {
  local parent_ref=$1
  local tree_ref=$2

  git checkout "$tree_ref" -- .
  git checkout "$parent_ref" -- .github/workflows .github/scripts/rebuild-rafaelgaspar.sh 2>/dev/null \
    || git checkout "$parent_ref" -- .github/scripts/rebuild-rafaelgaspar.sh 2>/dev/null || true
  git reset --soft "$parent_ref"
}

push_ref() {
  local ref=$1
  git push --force-with-lease "$ORIGIN_REMOTE" "${ref}:${ref}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --push)
      PUSH=true
      shift
      ;;
    --squash)
      SQUASH=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      [[ -z $UPSTREAM_TAG ]] || die "unexpected extra argument: $1"
      UPSTREAM_TAG=$1
      shift
      ;;
  esac
done

[[ -n $UPSTREAM_TAG ]] || die "upstream tag required"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "must run inside a git repository"
git fetch "$UPSTREAM_REMOTE" --tags --force
git fetch "$ORIGIN_REMOTE" --force --prune
git fetch "$ORIGIN_REMOTE" 'refs/heads/feat/*:refs/remotes/origin/feat/*' || true
if git remote get-url archive >/dev/null 2>&1; then
  git fetch archive --force --prune || true
fi

UPSTREAM_SHA=$(git rev-parse "${UPSTREAM_TAG}^{commit}") \
  || die "upstream tag not found: ${UPSTREAM_TAG} (remote ${UPSTREAM_REMOTE})"

tag=$(git describe --tags --exact-match "$UPSTREAM_SHA" 2>/dev/null || true)
[[ $tag =~ $UPSTREAM_TAG_PATTERN ]] \
  || die "upstream tag ${UPSTREAM_TAG} does not match expected pattern"

upstream_tag_sha=$(git rev-parse "${UPSTREAM_REMOTE}/${tag}^{commit}" 2>/dev/null) \
  || upstream_tag_sha=$(git rev-parse "${tag}^{commit}")
[[ $upstream_tag_sha == "$UPSTREAM_SHA" ]] \
  || die "local tag ${tag} does not match ${UPSTREAM_REMOTE}/${tag}"

git ls-remote --tags "$UPSTREAM_REMOTE" "refs/tags/${tag}" | grep -q . \
  || die "upstream remote has no tag ${tag} (refusing local/forged tag)"

log "integration branch: ${INTEGRATION_BRANCH}"
log "upstream tag: ${UPSTREAM_TAG} (${UPSTREAM_SHA})"

discover_stack
log "stack order (${#STACK[@]} branches):"
for branch in "${STACK[@]}"; do
  if [[ $branch == "$ROOT_FEAT" ]]; then
    printf '  - %s (base: %s)\n' "$branch" "$UPSTREAM_TAG"
  else
    printf '  - %s (base: %s)\n' "$branch" "${STACK_PARENT[$branch]}"
  fi
done
log "stack tip: ${STACK_TIP}"

if $DRY_RUN; then
  validate_integration_pointer "$(feat_remote "$INTEGRATION_BRANCH")" "$(feat_remote "$STACK_TIP")"
  log "dry run — stack valid; skipping rebase and push"
  exit 0
fi

parent_ref=$UPSTREAM_SHA
for branch in "${STACK[@]}"; do
  log "rebuild ${branch} on ${parent_ref}"
  git checkout -B "$branch" "$parent_ref"
  tree_ref=$(layer_tree_ref "$branch")
  history_ref=$(layer_history_ref "$branch")
  if [[ $branch == "$ROOT_FEAT" ]]; then
    count=$(git rev-list --count "${parent_ref}..${ORIGIN_REMOTE}/${branch}")
    if (( count > 0 )); then
      git cherry-pick "${parent_ref}..${ORIGIN_REMOTE}/${branch}"
      finalize_layer_commit "$branch" "$parent_ref" "$history_ref"
    fi
  else
    remote_tip=$(ref_tip "$tree_ref")
    if [[ $remote_tip != "$parent_ref" ]]; then
      apply_child_layer_tree "$parent_ref" "$tree_ref"
      git commit -m "$(pick_layer_subject "$branch" "$history_ref" "$parent_ref")"
    else
      finalize_layer_commit "$branch" "$parent_ref" "$history_ref"
    fi
  fi
  validate_stack_link "$branch" "$parent_ref"
  if $PUSH; then
    push_ref "$branch"
  fi
  parent_ref=$(ref_tip "$branch")
done

log "reset ${INTEGRATION_BRANCH} to ${STACK_TIP} (${parent_ref})"
git checkout -B "$INTEGRATION_BRANCH" "$parent_ref"

if $PUSH; then
  push_ref "$INTEGRATION_BRANCH"
fi

validate_integration_pointer "$INTEGRATION_BRANCH" "$STACK_TIP"

log "done"
