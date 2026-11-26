# ddev-craft-worktree

A DDEV add-on that gives every git worktree its own DDEV project, URL and database copy. A single `ddev worktree add feature/x` does all of it.

It was built for Craft CMS, but it works with any DDEV project. Two things set it apart from other worktree add-ons:

- **Craft defaults.** It copies `.env` and `config/license.key`, repoints the site URL, and runs `craft up` after the database import.
- **Copy-on-write clones.** Large untracked folders such as local asset volumes, `vendor` or build output are cloned with APFS `clonefile` on macOS, or reflinks on Btrfs/XFS. A worktree gets the whole folder instantly and uses no extra disk until a file in it changes. Changes in the worktree never touch the main checkout.

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

- **No tracked config changes.** The worktree gets an untracked `.ddev/config.local.yaml` that holds its project `name` (plus `upload_dirs`, if configured). DDEV merges that file over `config.yaml`, and DDEV's own `.ddev/.gitignore` already ignores it. If the main checkout has an uncommitted PHP or database version in `config.yaml`, that version is copied across too, so the dump imports into the same engine.
- **`.ddev/.env.web`.** If this file is tracked, it is marked `skip-worktree` in the worktree only, because DDEV rewrites it on every start.
- **Database seed.** The main project's database is copied with `ddev export-db` into a temp file, then `ddev import-db` loads it into the worktree, and the temp file is deleted. This is much faster and smaller than `ddev snapshot`. Never keep dumps in `.ddev/db_snapshots`: DDEV treats any `*.sql.gz` there as a snapshot.
- **Safe removal.** `rm` only deletes a project whose `config.local.yaml` carries this add-on's marker. It refuses the main checkout, and it refuses a worktree with uncommitted changes unless you pass `--force`.

## Configuration: `.ddev/worktree.conf`

This file is bash-sourced and paths are relative to the project root. Add-on updates never overwrite it.

| Setting | Default | Purpose |
|---|---|---|
| `WORKTREE_COPY_FILES` | `(.env)`, plus `config/license.key` for `craftcms` | Untracked files to copy. In `.env*` files, `://<project>.ddev.site` is rewritten to the worktree's URL. |
| `WORKTREE_CLONE_DIRS` | none | Untracked dirs to clone with copy-on-write, e.g. `(web/assets vendor)`. |
| `WORKTREE_UPLOAD_DIRS` | none | Dirs DDEV should bind-mount instead of syncing with Mutagen. Use for big asset folders so they aren't copied into a Docker volume per worktree. |
| `WORKTREE_POST_START` | `("ddev composer install")` if `composer.json` exists | Commands run after `ddev start`. |
| `WORKTREE_POST_IMPORT` | `("ddev craft up --interactive=0")` for `craftcms` | Commands run after the DB import. |
| `WORKTREE_DB_DIR` | empty (temp) | Where to keep dumps for `--reuse-db`. An env var of the same name wins. |

Example for a Craft site with local asset volumes and a webpack build:

```bash
WORKTREE_COPY_FILES=(.env config/license.key)
WORKTREE_CLONE_DIRS=(web/assets vendor)
WORKTREE_UPLOAD_DIRS=(web/assets)
WORKTREE_POST_START=("ddev composer install" "ddev npm ci" "ddev npm run build")
WORKTREE_POST_IMPORT=("ddev craft up --interactive=0")
```

### A note on clones and disk use

A cloned file still counts as a file (Spotlight, backups and file watchers see it), but it shares its data blocks with the original. `du` reports the full size; `df` shows the real cost. On filesystems without copy-on-write support, the add-on falls back to a normal copy and says so.

## Tests

```bash
brew install bats-core bats-core/bats-core/bats-{support,assert,file}
bats ./tests/test.bats --filter-tags '!release'
```
