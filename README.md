# ddev-craft-worktree

A DDEV add-on that gives every git worktree its own DDEV project, URL and database copy. A single `ddev worktree add feature/x` does all of it.

It was built for Craft CMS, but it works with any DDEV project that's a git repository. Three things set it apart from other worktree add-ons:

- **Craft defaults.** It copies `.env` and `config/license.key`, repoints the site URL, and runs `craft up` after the database import. It works on Craft 3.9, 4 and 5.
- **Little or no setup.** It finds local asset folders in your Craft project config, and it detects your front-end build from `package.json`. Run `ddev worktree config` to see what a project will get.
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
ddev worktree add feature/x --no-build       # skip npm/yarn install + build this time
ddev worktree init [worktree]                # provision a worktree made by an editor/agent/git
ddev worktree list                           # worktrees, branches, DDEV projects and URLs
ddev worktree config                         # settings a new worktree would get, and where each came from
ddev worktree rm new-thing [--force]         # ddev delete + git worktree remove (branch kept)
```

`feature/new-thing` becomes `../<checkout>.worktrees/new-thing`, served at `https://<project>-new-thing.ddev.site`.

## How it works

- **No tracked config changes.** The worktree gets an untracked `.ddev/config.local.yaml` that holds its project `name` (plus `upload_dirs`, if configured). DDEV merges that file over `config.yaml`, and DDEV's own `.ddev/.gitignore` already ignores it. If the main checkout has an uncommitted PHP or database version in `config.yaml`, that version is copied across too, so the dump imports into the same engine.
- **`.ddev/.env.web`.** If this file is tracked, it is marked `skip-worktree` in the worktree only, because DDEV rewrites it on every start.
- **Database seed.** The main project's database is copied with `ddev export-db` into a temp file, then `ddev import-db` loads it into the worktree, and the temp file is deleted. This is much faster and smaller than `ddev snapshot`. Never keep dumps in `.ddev/db_snapshots`: DDEV treats any `*.sql.gz` there as a snapshot.
- **Safe removal.** `rm` only deletes a project whose `config.local.yaml` carries this add-on's marker. It refuses the main checkout, and it refuses a worktree with uncommitted changes unless you pass `--force`.

## Configuration: `.ddev/worktree.conf`

This file is bash-sourced and paths are relative to the project root. Add-on updates never overwrite it. Anything you set wins, even an empty list: `WORKTREE_POST_START=()` turns the build off. Anything you leave unset gets the default below, and `ddev worktree config` marks each setting `[conf]`, `[default]` or `[detected]`.

| Setting | Default | Purpose |
|---|---|---|
| `WORKTREE_COPY_FILES` | `(.env)`, plus `config/license.key` for `craftcms` | Untracked files to copy. In `.env*` files, `://<project>.ddev.site` is rewritten to the worktree's URL. |
| `WORKTREE_CLONE_DIRS` | Craft local asset folders (see below) | Untracked dirs to clone with copy-on-write, e.g. `(web/assets vendor)`. |
| `WORKTREE_UPLOAD_DIRS` | Same as the detected asset folders | Dirs DDEV should bind-mount instead of syncing with Mutagen, so big asset folders aren't copied into a Docker volume per worktree. Dirs the main `config.yaml` already lists are skipped, because DDEV appends this list to that one. |
| `WORKTREE_POST_START` | `composer install`, then the detected front-end build (see below) | Commands run after `ddev start`. |
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

### Asset folder detection (craftcms)

Every `path:` in `config/project/` is read, which covers Craft 3 volumes and Craft 4/5 filesystems. `$ENV_VAR` values are resolved from `.env`. Paths under `@webroot`, `@root` or `/var/www/html` that exist in the main checkout are kept. Sibling folders are collapsed to their parent, so `web/assets/images` and `web/assets/docs` become `web/assets`, but never up to the docroot itself. Remote volumes (Servd, S3) have no local path, so nothing is cloned for them.

### Front-end build detection

If `package.json` exists, dependencies are installed with `ddev npm ci` (if there's a `package-lock.json`), `ddev yarn install --frozen-lockfile` (if there's a `yarn.lock`) or `ddev npm install`. Then the first of these scripts that exists is run: `build`, `production`, `prod`. Everything runs inside the web container, on the project's `nodejs_version`.

| Pipeline | What happens |
|---|---|
| Vite (with or without craft-vite), webpack | `build` runs. `ddev npm run dev` also works in a worktree, as long as your Vite config takes its origin from `PRIMARY_SITE_URL`, `DDEV_PRIMARY_URL` or `@web` rather than a hardcoded hostname. |
| Laravel Mix | `production` runs. |
| gulp, or anything without one of those scripts | Nothing is built, and the add-on tells you so. Set `WORKTREE_POST_START` (e.g. `"ddev npx gulp build"`), or clone the built output from the main checkout with `WORKTREE_CLONE_DIRS`. |

### A note on clones and disk use

A cloned file still counts as a file (Spotlight, backups and file watchers see it), but it shares its data blocks with the original. `du` reports the full size; `df` shows the real cost. On filesystems without copy-on-write support, the add-on falls back to a normal copy and says so.

## Tests

```bash
brew install bats-core bats-core/bats-core/bats-{support,assert,file}
bats ./tests/test.bats --filter-tags '!release'
```
