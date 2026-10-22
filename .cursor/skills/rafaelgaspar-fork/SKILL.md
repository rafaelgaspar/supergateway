---
name: rafaelgaspar-fork
description: >-
  Work with rafaelgaspar application forks (homepage, supergateway, xpra,
  xpra-html5, otbr-insight) — stacked feat branches, rafaelgaspar integration pointer,
  upstream tag rebuilds. Use when changing fork branches, stack order, tag-bump,
  or fork-pack shared files.
disable-model-invocation: true
---

# rafaelgaspar forks

Shared workflow for the public application forks. Clone them under
`~/Projects/ThirdParty/<name>`. Shared scripts, tag-bump, and this skill live in
[rafaelgaspar/fork-pack](https://github.com/rafaelgaspar/fork-pack)
(`~/Projects/ThirdParty/fork-pack`; reusable tag-bump in `.github/workflows`,
skills in `dot-cursor/` vendored onto forks as `.cursor/`). Per-fork remotes
and tag filters: `members.yaml`.

| Fork                                                         | Upstream                                                                  | Ships from `rafaelgaspar`           |
| ------------------------------------------------------------ | ------------------------------------------------------------------------- | ----------------------------------- |
| [homepage](https://github.com/rafaelgaspar/homepage)         | [gethomepage/homepage](https://github.com/gethomepage/homepage)           | `ghcr.io/rafaelgaspar/homepage`     |
| [supergateway](https://github.com/rafaelgaspar/supergateway) | [supercorp-ai/supergateway](https://github.com/supercorp-ai/supergateway) | `ghcr.io/rafaelgaspar/supergateway` |
| [xpra](https://github.com/rafaelgaspar/xpra)                 | [Xpra-org/xpra](https://github.com/Xpra-org/xpra)                         | GitHub release + overlay `.deb`     |
| [xpra-html5](https://github.com/rafaelgaspar/xpra-html5)     | [Xpra-org/xpra-html5](https://github.com/Xpra-org/xpra-html5)             | GitHub release + HTML5 tarball      |
| [otbr-insight](https://github.com/rafaelgaspar/otbr-insight) | [sumitbirla/otbr-insight](https://github.com/sumitbirla/otbr-insight)     | `ghcr.io/rafaelgaspar/otbr-insight` |

This skill is **fork workflow only**. Deploy config (Helm, secrets, image overlays)
belongs in the private cluster repo, not in these public forks.

## Repos and branches

| Branch            | Role                                                                                  |
| ----------------- | ------------------------------------------------------------------------------------- |
| `main` / `master` | Upstream mirror only — auto-sync, no features                                         |
| `feat/<name>`     | One feature; branch from the **current stack tip** (or `feat/rafaelgaspar` for infra) |
| `rafaelgaspar`    | Points at the stack tip — **only this branch ships** (default branch)                 |

**Invariant:** `feat/rafaelgaspar` is always the stack root (infra overlay from
fork-pack: rebuild script, tag-bump caller, this skill, fork README). Upstream
CI workflows are **deleted** on the fork, not edited, so tag bumps do not
conflict on workflow YAML.

## Stacked feat branches (git is the source of truth)

Features form a **linear stack**. Each `feat/*` branch carries **exactly one commit** on its parent.

```text
<upstream-tag>
 └── feat/rafaelgaspar
      └── feat/<next>
           └── feat/<tip>  ← rafaelgaspar reset --hard here
```

Order is defined by **git merge-base**, not a manifest file:

- `feat/rafaelgaspar` must be based on the upstream release tag.
- Every other `feat/*` must be based on exactly one parent **feat branch tip**.
- The stack must be **linear** (one child per parent).
- `rafaelgaspar` must match the stack tip commit.

Inspect:

```sh
git log --oneline --graph --decorate feat/rafaelgaspar feat/<...> rafaelgaspar
```

Validate without changing anything (`tag_filter` / example tags: `members.yaml`):

```sh
FORK_PACK_SCRIPTS=~/Projects/ThirdParty/fork-pack/scripts \
  ~/Projects/ThirdParty/fork-pack/scripts/rebuild-rafaelgaspar.sh --dry-run vX.Y.Z
```

## Adding a feature

1. Branch from the **current stack tip** (not directly from the upstream tag):

   ```sh
   git fetch origin
   git checkout -B feat/<name> origin/<stack-tip>
   ```

2. Implement on `feat/<name>` (squash to one commit before publishing).
3. Publish integration:

   ```sh
   git checkout rafaelgaspar
   git reset --hard feat/<name>
   git push --force-with-lease origin rafaelgaspar
   ```

   The per-fork publish workflow runs on push to `rafaelgaspar`.

Do **not** commit features to the upstream default branch or maintain parallel
squash-merge history on `rafaelgaspar`. Do **not** export patch tarballs — the
fork image or release tag is the artifact.

## Upstream tag bump

When upstream publishes a git tag **T** matching `tag_filter` in `members.yaml`
(a GitHub Release is not required), the fork's thin tag-bump caller runs
`rafaelgaspar/fork-pack` `rebuild-rafaelgaspar.sh --squash --push`:

1. Overlay fork-owned files onto **T** (ROOT); cherry-pick each child layer.
2. Squash each layer to one commit on its parent.
3. Reset `rafaelgaspar` to the stack tip and force-push with lease.

Scheduled tag-bump skips only when that tag's **commit SHA** is already an
ancestor of **`rafaelgaspar`** (the shipped pointer), not `feat/rafaelgaspar`.
A retag of the same name (new SHA) rebuilds. Rebuilds register **mergiraf**
as a local merge driver; leftover conflicts post to Discord `#forks-tag-bump`
(secret `DISCORD_WEBHOOK_FORKS_TAG_BUMP`). Layers are pushed only after the
whole stack is rebuilt locally.

Manual replay:

```sh
FORK_PACK_SCRIPTS=~/Projects/ThirdParty/fork-pack/scripts \
  ~/Projects/ThirdParty/fork-pack/scripts/rebuild-rafaelgaspar.sh --squash --push vX.Y.Z
```

Change rebuild/tag-bump **in fork-pack**, not by forking copies in the five
repos.

## One commit per feat branch

**Always one commit per `feat/*` layer.** Tag-bump passes `--squash` so
`git log <upstream-tag>..rafaelgaspar` shows one commit per shipped feature.
While developing, keep a single commit on the feat branch (amend or squash
before pushing integration).

## Scope

| Belongs on the fork (`feat/*`)    | Does not belong on these public repos  |
| --------------------------------- | -------------------------------------- |
| App source changes                | Deploy secrets, private cluster config |
| Per-fork publish workflow         | Private infra paths or repo names      |
| Pointer updates to `rafaelgaspar` | `PLAN-*.md` planning notes             |

Shared rebuild/tag-bump/skill edits belong in **fork-pack**.

## Agent checklist

- [ ] Work on a **`feat/*`** branch stacked on the current tip, not the upstream default branch or `rafaelgaspar` directly (except pointer updates).
- [ ] **`feat/rafaelgaspar` remains the stack root** on the upstream release tag.
- [ ] New features branch from the stack tip; never create parallel siblings (linear stack only).
- [ ] **One commit per feat branch** before publishing integration.
- [ ] Publish with `rafaelgaspar` reset to the new tip, not squash merges on `rafaelgaspar`.
- [ ] No private deploy repo names, cluster paths, or `PLAN-*.md` in commits here.
- [ ] Shared automation changes go to **rafaelgaspar/fork-pack**.
