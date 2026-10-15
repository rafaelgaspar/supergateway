#!/usr/bin/env bash
# Rebuild stacked feat/* branches on upstream release tag T and point rafaelgaspar at the stack tip.
# Stack order is derived from commit depth on the upstream tag (linear stack).
# Shared across rafaelgaspar forks: https://github.com/rafaelgaspar/fork-pack
set -euo pipefail

INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-rafaelgaspar}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
ORIGIN_REMOTE="${ORIGIN_REMOTE:-origin}"
ROOT_FEAT="${ROOT_FEAT:-feat/rafaelgaspar}"
# v1.2.3 (semver forks) or v21 (integer tags). Override with UPSTREAM_TAG_PATTERN.
UPSTREAM_TAG_PATTERN="${UPSTREAM_TAG_PATTERN:-^v[0-9]+(\\.[0-9]+\\.[0-9]+)?$}"

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
      # ROOT always leads. Extra infra commits on feat/rafaelgaspar must not
      # sort it after a child that is still based on an older ROOT tip.
      if [[ $branch == "$ROOT_FEAT" ]]; then
        order=0
      else
        order=$((count + 1))
      fi
      printf '%d\t%s\n' "$order" "$branch"
    done | sort -n | cut -f2-
  )

  [[ ${STACK[0]} == "$ROOT_FEAT" ]] \
    || die "${ROOT_FEAT} must lead the stack closest to ${UPSTREAM_TAG}; got ${STACK[0]}"

  # Drop leftover feat/* commits whose tree matches the previous layer.
  local compact=() prev_tree="" tree
  for branch in "${STACK[@]}"; do
    tree=$(git rev-parse "$(feat_remote "$branch")^{tree}")
    if [[ -n $prev_tree && $tree == "$prev_tree" ]]; then
      log "skip ${branch}: same tree as previous layer"
      continue
    fi
    compact+=("$branch")
    prev_tree=$tree
  done
  STACK=("${compact[@]}")
  ((${#STACK[@]} > 0)) || die "stack empty after collapsing duplicate trees"

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
  local dir=${FORK_PACK_SCRIPTS:-}
  local script_path=${CANONICAL_REBUILD_SCRIPT:-}
  local pack_root skill_src src dest

  mkdir -p .github/scripts
  if [[ -n $dir && -d $dir ]]; then
    for src in rebuild-rafaelgaspar.sh resolve-integration-tag.sh; do
      [[ -f $dir/$src ]] || continue
      dest=".github/scripts/${src}"
      cp "$dir/$src" "$dest"
      chmod +x "$dest"
      git add "$dest"
    done
    pack_root=$(cd "$dir/.." && pwd)
    skill_src="${pack_root}/dot-cursor/skills/rafaelgaspar-fork"
    if [[ -d $skill_src ]]; then
      mkdir -p .cursor/skills
      rm -rf .cursor/skills/rafaelgaspar-fork
      cp -a "$skill_src" .cursor/skills/rafaelgaspar-fork
      git add .cursor/skills/rafaelgaspar-fork
    fi
    if [[ -f .github/workflows/rafaelgaspar-tag-bump-reusable.yaml ]]; then
      git rm -f --ignore-unmatch .github/workflows/rafaelgaspar-tag-bump-reusable.yaml
    fi
  elif [[ -n $script_path && -f $script_path ]]; then
    cp "$script_path" .github/scripts/rebuild-rafaelgaspar.sh
    chmod +x .github/scripts/rebuild-rafaelgaspar.sh
    git add .github/scripts/rebuild-rafaelgaspar.sh
  else
    return 0
  fi
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

  (( count > 0 )) || count=$(git rev-list --count "${parent_ref}..HEAD")
  (( count > 0 )) || return 0

  desired=$(pick_layer_subject "$branch" "$source_ref" "$parent_ref")
  current=$(git log -1 --format=%s)
  if [[ $current != "$desired" ]]; then
    git commit --amend -m "$desired"
  fi
}

commit_layer() {
  local message=$1
  if git diff --cached --quiet && git diff --quiet; then
    git commit --allow-empty -m "$message"
  else
    git add -A
    git commit -m "$message"
  fi
}

# Drop upstream GitHub Actions so the fork only runs rafaelgaspar-* workflows.
# Deleting (instead of editing `on:`) is conflict-free across upstream tag bumps.
disable_upstream_workflows() {
  local f
  shopt -s nullglob
  for f in .github/workflows/*.yml .github/workflows/*.yaml; do
    [[ -e $f ]] || continue
    [[ $(basename "$f") == rafaelgaspar-* ]] && continue
    git rm -f --ignore-unmatch "$f" >/dev/null
  done
}

ensure_gitignore_fork_block() {
  local tree_ref=$1
  local block
  [[ -f .gitignore ]] || touch .gitignore
  grep -q '# agent skills' .gitignore && return 0
  block=$(git show "${tree_ref}:.gitignore" 2>/dev/null | awk '/# agent skills/,0') || return 0
  [[ -n $block ]] || return 0
  printf '\n%s\n' "$block" >> .gitignore
}

ensure_readme_fork_section() {
  local tree_ref=$1
  python3 - "$tree_ref" <<'PY'
import re, subprocess, sys
from pathlib import Path

tree_ref = sys.argv[1]
path = Path("README.md")
if not path.exists():
    raise SystemExit(0)
text = path.read_text()
if re.search(r"^## rafaelgaspar fork\s*$", text, re.M):
    raise SystemExit(0)
try:
    origin = subprocess.check_output(["git", "show", f"{tree_ref}:README.md"], text=True)
except subprocess.CalledProcessError:
    raise SystemExit(0)
section = []
grab = False
for line in origin.splitlines(True):
    if line.startswith("## rafaelgaspar fork"):
        grab = True
    if not grab:
        continue
    if section and (
        line.startswith("# ")
        or (line.startswith("## ") and not line.startswith("## rafaelgaspar fork"))
    ):
        break
    section.append(line)
    if line.strip() == "---" and len(section) > 1:
        break
if not section:
    raise SystemExit(0)
block = "".join(section).rstrip() + "\n\n"
match = re.search(r"^# ", text, re.M)
if match:
    path.write_text(text[: match.start()] + block + text[match.start() :])
else:
    parts = text.split("\n", 1)
    rest = parts[1].lstrip("\n") if len(parts) == 2 else ""
    path.write_text(parts[0] + "\n\n" + block + rest)
PY
}

# Overlay fork-owned files onto the new upstream tag. Never cherry-pick the old
# ROOT commit: that patch edits upstream workflows/README and conflicts whenever
# upstream touches the same files.
apply_root_layer_tree() {
  local parent_ref=$1
  local tree_ref=$2
  local paths

  mapfile -t paths < <(
    git ls-tree -r --name-only "$tree_ref" \
      | grep -E '^(\.github/(scripts/|workflows/rafaelgaspar-)|\.cursor/skills|\.claude/skills|packaging/rafaelgaspar-overlay)' \
      || true
  )
  if ((${#paths[@]} > 0)); then
    git checkout "$tree_ref" -- "${paths[@]}"
  fi
  # Only overlay Dockerfile when the ROOT layer itself changed it.
  if git cat-file -e "${tree_ref}:Dockerfile" 2>/dev/null; then
    old_parent=$(git rev-parse "${tree_ref}^" 2>/dev/null) || old_parent=""
    if [[ -n $old_parent ]] && ! git diff --quiet "$old_parent" "$tree_ref" -- Dockerfile; then
      git checkout "$tree_ref" -- Dockerfile
    fi
  fi

  disable_upstream_workflows
  ensure_gitignore_fork_block "$tree_ref"
  ensure_readme_fork_section "$tree_ref"
  git add -A
}

# Keep unique Jest it() blocks from both sides when a test file conflicts
# because upstream and a feat layer each added a test at the same place.
resolve_jest_test_conflicts() {
  python3 - <<'PY'
import re, subprocess, sys
from pathlib import Path

unmerged = subprocess.check_output(
    ["git", "diff", "--name-only", "--diff-filter=U"], text=True
).splitlines()
if not unmerged:
    raise SystemExit(1)

test_re = re.compile(r"\.(test|spec)\.(js|jsx|ts|tsx)$")

def extract_it_blocks(src: str):
    blocks = []
    i = 0
    while True:
        m = re.search(r"\n[ \t]*it\s*\(\s*(['\"])", src[i:])
        if not m:
            break
        start = i + m.start() + 1
        q = m.group(1)
        name_start = i + m.end()
        name_end = src.find(q, name_start)
        if name_end < 0:
            break
        name = src[name_start:name_end]
        paren = src.find("{", name_end)
        if paren < 0:
            break
        depth = 0
        j = paren
        while j < len(src):
            c = src[j]
            if c in ("'", '"', "`"):
                esc = False
                j += 1
                while j < len(src):
                    d = src[j]
                    if esc:
                        esc = False
                    elif d == "\\":
                        esc = True
                    elif d == c:
                        j += 1
                        break
                    j += 1
                continue
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    k = j + 1
                    while k < len(src) and src[k] in " \t":
                        k += 1
                    if src.startswith(");", k):
                        k += 2
                    blocks.append((name, src[start:k]))
                    i = k
                    break
            j += 1
        else:
            break
    return blocks

remaining = []
resolved_any = False
for path in unmerged:
    if not test_re.search(path):
        remaining.append(path)
        continue
    ours = subprocess.check_output(["git", "show", f":2:{path}"], text=True)
    theirs = subprocess.check_output(["git", "show", f":3:{path}"], text=True)
    ours_blocks = extract_it_blocks(ours)
    theirs_blocks = extract_it_blocks(theirs)
    ours_names = {n for n, _ in ours_blocks}
    theirs_names = [n for n, _ in theirs_blocks]
    missing = [(n, b) for n, b in theirs_blocks if n not in ours_names]
    if not missing:
        remaining.append(path)
        continue
    out = ours
    failed = False
    for name, block in missing:
        idx = theirs_names.index(name)
        following = next((later for later in theirs_names[idx + 1 :] if later in ours_names), None)
        insertion = block.rstrip() + "\n\n"
        if following is None:
            out = out.rstrip() + "\n\n" + insertion
            continue
        pos = -1
        for quote in ('"', "'"):
            marker = f"it({quote}{following}{quote}"
            pos = out.find(marker)
            if pos >= 0:
                break
        if pos < 0:
            failed = True
            break
        line_start = out.rfind("\n", 0, pos) + 1
        out = out[:line_start] + insertion + out[line_start:]
    if failed or "<<<<<<<" in out:
        remaining.append(path)
        continue
    Path(path).write_text(out)
    subprocess.check_call(["git", "add", path])
    resolved_any = True

if remaining:
    print("unresolved conflicts: " + ", ".join(remaining), file=sys.stderr)
    raise SystemExit(1)
if not resolved_any:
    raise SystemExit(1)
print("resolved Jest it() additions in test files")
PY
}

# Apply the old layer's patch onto the new parent (3-way merge vs the old parent).
# Do not checkout the old tree — that would revert upstream files to the previous tag.
apply_child_layer_patch() {
  local parent_ref=$1
  local tree_ref=$2
  local old_parent

  old_parent=$(git rev-parse "${tree_ref}^")
  if [[ $(ref_tip "$tree_ref") == $(ref_tip "$old_parent") ]]; then
    return 0
  fi
  git cherry-pick --quit >/dev/null 2>&1 || true
  cherry_ok=true
  if ! git cherry-pick --no-commit --empty=keep "${old_parent}..${tree_ref}"; then
    cherry_ok=false
  fi
  # Pack files belong to ROOT. Restore them so a child docs tweak cannot
  # conflict on the vendored skill or workflows.
  git checkout "$parent_ref" -- \
    .github/workflows \
    .github/scripts \
    .cursor/skills/rafaelgaspar-fork \
    .claude/skills \
    2>/dev/null || true
  git add -A -- \
    .github/workflows \
    .github/scripts \
    .cursor/skills/rafaelgaspar-fork \
    .claude/skills \
    2>/dev/null || true
  if ! $cherry_ok; then
    if git diff --name-only --diff-filter=U | grep -q .; then
      if ! resolve_jest_test_conflicts; then
        die "cherry-pick of ${tree_ref} onto ${parent_ref} conflicted"
      fi
    fi
    git cherry-pick --quit >/dev/null 2>&1 || true
  fi
  git add -A
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
[[ $UPSTREAM_TAG =~ $UPSTREAM_TAG_PATTERN ]] \
  || die "upstream tag ${UPSTREAM_TAG} does not match expected pattern"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "must run inside a git repository"
git fetch "$UPSTREAM_REMOTE" --tags --force
git fetch "$ORIGIN_REMOTE" --force --prune
git fetch "$ORIGIN_REMOTE" 'refs/heads/feat/*:refs/remotes/origin/feat/*' || true
if git remote get-url archive >/dev/null 2>&1; then
  git fetch archive --force --prune || true
fi

UPSTREAM_SHA=$(git rev-parse "${UPSTREAM_TAG}^{commit}") \
  || die "upstream tag not found: ${UPSTREAM_TAG} (remote ${UPSTREAM_REMOTE})"

# Compare tag *objects* (annotated tag SHA != peeled commit). Some hosts omit
# the refs/tags/T^{} line from ls-remote, so do not treat the tag object as a commit.
local_tag_obj=$(git rev-parse "${UPSTREAM_TAG}")
remote_tag_obj=$(
  git ls-remote --tags "$UPSTREAM_REMOTE" "refs/tags/${UPSTREAM_TAG}" \
    | awk -v tag="refs/tags/${UPSTREAM_TAG}" '$2 == tag { print $1; exit }'
)
[[ -n $remote_tag_obj ]] \
  || die "upstream remote has no tag ${UPSTREAM_TAG} (refusing local/forged tag)"
[[ $local_tag_obj == "$remote_tag_obj" ]] \
  || die "local tag ${UPSTREAM_TAG} (${local_tag_obj}) != upstream (${remote_tag_obj}); retag not fetched"

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
  git checkout --ignore-other-worktrees -B "$branch" "$parent_ref"
  tree_ref=$(layer_tree_ref "$branch")
  history_ref=$(layer_history_ref "$branch")
  if [[ $branch == "$ROOT_FEAT" ]]; then
    apply_root_layer_tree "$parent_ref" "$tree_ref"
    commit_layer "$(pick_layer_subject "$branch" "$history_ref" "$parent_ref")"
    finalize_layer_commit "$branch" "$parent_ref" "$history_ref"
  else
    remote_tip=$(ref_tip "$tree_ref")
    if [[ $remote_tip != "$parent_ref" ]]; then
      apply_child_layer_patch "$parent_ref" "$tree_ref"
      commit_layer "$(pick_layer_subject "$branch" "$history_ref" "$parent_ref")"
      finalize_layer_commit "$branch" "$parent_ref" "$history_ref"
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
git checkout --ignore-other-worktrees -B "$INTEGRATION_BRANCH" "$parent_ref"

if $PUSH; then
  push_ref "$INTEGRATION_BRANCH"
fi

validate_integration_pointer "$INTEGRATION_BRANCH" "$STACK_TIP"

log "done"
