# ddev-craft-worktree

A DDEV add-on that gives every git worktree its own DDEV project, URL and database copy. A single `ddev worktree add feature/x` does all of it.

It was built for Craft CMS, and works with any DDEV project whose `.ddev/config.yaml` is committed at the root of a git repository. Other project types get the same worktree, URL and database handling; anything type-specific goes in a hook.

- **Craft defaults.** It copies `.env` and `config/license.key`, repoints the site URL, and runs `craft up` after the database import.
- **Copy-on-write clones.** Large untracked folders such as local asset volumes are cloned with APFS `clonefile` on macOS, or reflinks on Btrfs/XFS. A worktree gets the whole folder instantly and uses no extra disk until a file in it changes. Changes in the worktree never touch the main checkout.
- **Your DDEV config does the rest.** Front-end builds, `upload_dirs` and other setup live in `.ddev/config.yaml` (e.g. `hooks: post-start:`), which every worktree already gets from git.

## Install

```bash
ddev add-on get paulstone/ddev-craft-worktree
```

This adds `.ddev/commands/host/worktree` and, if it doesn't already exist, `.ddev/worktree.conf` (created from `.ddev/worktree.conf.example`). Commit the command and `worktree.conf`. Updating with `ddev add-on get` replaces the command and the example but never touches your `worktree.conf`.

## Commands

```bash
ddev worktree add feature/new-thing          # worktree + DDEV project + fresh DB copy
ddev worktree add feature/x --from main      # base a new branch on another ref
ddev worktree add feature/x --no-db          # skip the database seed
ddev worktree add feature/x --no-start       # files only; don't start DDEV
ddev worktree add feature/x --keep-db ~/dbs  # keep the seed dump
ddev worktree add feature/x --reuse-db       # reuse the newest kept dump
ddev worktree init [worktree]                # provision a worktree made by an editor/agent/git
ddev worktree list                           # worktrees, branches, DDEV projects and URLs
ddev worktree rm new-thing [--force]         # ddev delete + git worktree remove (branch kept)
```

`feature/new-thing` becomes `../<checkout>.worktrees/new-thing`, served at `https://<project>-new-thing.ddev.site`.

## How it works

- **No tracked config changes.** The worktree gets an untracked `.ddev/config.local.yaml` that holds only its project `name`. DDEV merges that file over `config.yaml`, and DDEV's own `.ddev/.gitignore` already ignores it.
- **`.ddev/.env.web`.** If this file is tracked, it is marked `skip-worktree` in the worktree only, because DDEV rewrites it on every start.
- **Database seed.** The main project's database is copied with `ddev export-db` into a temp file and loaded with `ddev import-db`, then the temp file is deleted. The worktree is started with `--skip-hooks`, the dump is imported, then `ddev start` runs again so your DDEV post-start hooks see real data rather than an empty database. Projects that omit the `db` container are not seeded. Never keep dumps in `.ddev/db_snapshots`: DDEV treats any `*.sql.gz` there as a snapshot.
- **Safe removal.** `rm` only deletes a project whose `config.local.yaml` carries this add-on's marker. It refuses the main checkout, and it refuses a worktree with uncommitted changes unless you pass `--force`.

## Configuration: `.ddev/worktree.conf`

This file is bash-sourced and paths are relative to the project root. Add-on updates never overwrite it. Anything you set wins, even an empty list: `WORKTREE_POST_START=()` turns `composer install` off.

| Setting | Default | Purpose |
|---|---|---|
| `WORKTREE_COPY_FILES` | `(.env)`, plus `config/license.key` for `craftcms` | Untracked files to copy. In `.env*` files, `://<project>.ddev.site` is rewritten to the worktree's URL. |
| `WORKTREE_CLONE_DIRS` | none | Untracked dirs to clone with copy-on-write, e.g. `(web/assets)`. A dir that only holds tracked files (a `.gitkeep`) is still cloned into. |
| `WORKTREE_POST_START` | `("ddev composer install")` if there's a `composer.json` | Commands run after `ddev start` and its DDEV hooks. |
| `WORKTREE_POST_IMPORT` | `("ddev craft up --interactive=0")` for `craftcms` | Commands run after the DB import. |
| `WORKTREE_DB_DIR` | empty (temp) | Where to keep dumps for `--reuse-db`. An env var of the same name wins; `--keep-db` wins over both. |

Hook commands can use `$WORKTREE_URL`, `$WORKTREE_PROJECT`, `$WORKTREE_DIR`, `$MAIN_URL`, `$MAIN_PROJECT` and `$MAIN_ROOT`. For example, WordPress keeps its URL in the database:

```bash
WORKTREE_POST_IMPORT=('ddev wp search-replace "$MAIN_URL" "$WORKTREE_URL" --all-tables')
```

A typical Craft site with local asset volumes:

```bash
WORKTREE_CLONE_DIRS=(web/assets)
```

### Upgrading from 1.1

1.2 no longer detects Craft asset folders or front-end builds, and `ddev worktree config` and `--no-build` are gone. List asset folders in `WORKTREE_CLONE_DIRS`, put builds in DDEV's `hooks: post-start:` (or `WORKTREE_POST_START`), and put `upload_dirs` in `.ddev/config.yaml`. `WORKTREE_UPLOAD_DIRS` is ignored, with a notice.

### A note on clones and disk use

A cloned file still counts as a file (Spotlight, backups and file watchers see it), but it shares its data blocks with the original. `du` reports the full size; `df` shows the real cost. Where copy-on-write isn't available the add-on makes a normal copy (on Linux, GNU `cp --reflink=auto` falls back silently).

## Tests

```bash
brew install bats-core bats-core/bats-core/bats-{support,assert,file}
bats ./tests/test.bats --filter-tags '!release'
```
