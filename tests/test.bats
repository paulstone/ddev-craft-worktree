#!/usr/bin/env bats

# Run locally (needs bats-core, bats-assert, bats-file, bats-support):
#   bats ./tests/test.bats
# To exclude release tests:
#   bats ./tests/test.bats --filter-tags '!release'

setup() {
  set -eu -o pipefail

  export GITHUB_REPO=paulstone/ddev-craft-worktree

  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"
  bats_load_library bats-assert
  bats_load_library bats-file
  bats_load_library bats-support

  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
  export PROJNAME="test-craft-worktree"
  mkdir -p "${HOME}/tmp"
  export TESTDIR="$(mktemp -d "${HOME}/tmp/${PROJNAME}.XXXXXX")"
  export WTDIR="${TESTDIR}.worktrees"
  export DBDIR="${TESTDIR}.dbs"
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true
  export CI=true
  delete_projects
  cd "${TESTDIR}"

  # A committed DDEV project with an untracked .env and an untracked asset folder.
  git init -q -b main .
  git config user.email test@example.com
  git config user.name test
  run ddev config --project-name="${PROJNAME}" --project-type=php --docroot=web --project-tld=ddev.site
  assert_success
  mkdir -p web/assets/images
  echo '<?php readfile(__DIR__ . "/../.env");' > web/index.php
  echo 'img' > web/assets/images/a.txt
  printf '.env\nweb/assets/\n' > .gitignore
  printf 'PRIMARY_SITE_URL="https://%s.ddev.site"\n' "${PROJNAME}" > .env
  git add .gitignore web/index.php .ddev/config.yaml
  git commit -qm init
}

delete_projects() {
  local p
  for p in "${PROJNAME}" "${PROJNAME}-smoke" "${PROJNAME}-again"; do
    ddev delete -Oy "$p" >/dev/null 2>&1 || true
  done
}

install_addon() {
  run ddev add-on get "${DIR}"
  assert_success
  assert_file_exists .ddev/commands/host/worktree
  assert_file_exists .ddev/worktree.conf
  echo 'WORKTREE_CLONE_DIRS=(web/assets)' >> .ddev/worktree.conf
}

teardown() {
  set -eu -o pipefail
  delete_projects
  if [ -n "${GITHUB_ENV:-}" ]; then
    [ -e "${GITHUB_ENV:-}" ] && echo "TESTDIR=${TESTDIR}" >> "${GITHUB_ENV}"
  else
    [ "${TESTDIR}" != "" ] && rm -rf "${TESTDIR}" "${WTDIR}" "${DBDIR}"
  fi
}

@test "add --no-start scaffolds the worktree, list shows it, rm removes it" {
  set -eu -o pipefail
  install_addon

  run ddev worktree add feature/smoke --no-start
  assert_success
  local wt="${WTDIR}/smoke"
  assert_file_exists "${wt}/.ddev/config.local.yaml"
  run cat "${wt}/.ddev/config.local.yaml"
  assert_output --partial "name: ${PROJNAME}-smoke"
  refute_output --partial "upload_dirs"
  run cat "${wt}/.env"
  assert_output --partial "https://${PROJNAME}-smoke.ddev.site"
  assert_file_exists "${wt}/web/assets/images/a.txt"
  run git -C "${wt}" status --porcelain
  assert_output ""

  run ddev worktree list
  assert_success
  assert_output --partial "${PROJNAME}-smoke"

  # The main checkout and unprovisioned worktrees are never deleted.
  run ddev worktree rm "$(basename "${TESTDIR}")"
  assert_failure
  assert_output --partial "Refusing to remove the main worktree"

  run ddev worktree rm smoke
  assert_success
  assert_dir_not_exists "${wt}"
  assert_dir_not_exists "${WTDIR}"
  assert_dir_exists "${TESTDIR}/.ddev"
}

@test "a clone dir holding only tracked files is still cloned; unsafe entries are skipped" {
  set -eu -o pipefail
  mkdir -p web/uploads
  printf '*\n!.gitkeep\n' > web/uploads/.gitignore
  touch web/uploads/.gitkeep
  echo 'up' > web/uploads/u.txt
  git add -f web/uploads/.gitignore web/uploads/.gitkeep && git commit -qm uploads
  run ddev add-on get "${DIR}"
  assert_success
  echo 'WORKTREE_CLONE_DIRS=("" .. web/uploads)' >> .ddev/worktree.conf

  run ddev worktree add feature/smoke --no-start
  assert_success
  assert_output --partial "Skipping WORKTREE_CLONE_DIRS entry ''"
  assert_output --partial "Skipping WORKTREE_CLONE_DIRS entry '..'"
  assert_file_exists "${WTDIR}/smoke/web/uploads/u.txt"
  assert_file_exists "${WTDIR}/smoke/web/index.php"
  run git -C "${WTDIR}/smoke" status --porcelain
  assert_output ""
}

@test "add seeds the database before DDEV hooks run, keeps and reuses dumps, and exports hook variables" {
  set -eu -o pipefail
  # A DDEV post-start hook that reads the database: it must see the seeded row.
  cat >> .ddev/config.yaml <<'EOF'
hooks:
  post-start:
    - exec: "mysql -N -e 'select id from seeded' > /var/www/html/hookdb.txt 2>&1 || true"
EOF
  printf 'hookdb.txt\nhookvars.txt\n' >> .gitignore
  git add -A && git commit -qm hooks
  install_addon
  cat >> .ddev/worktree.conf <<'EOF'
WORKTREE_POST_IMPORT=('echo "$MAIN_URL -> $WORKTREE_URL ($WORKTREE_PROJECT)" > "$WORKTREE_DIR/hookvars.txt"')
EOF
  run ddev start -y
  assert_success
  run ddev mysql -e "create table seeded (id int); insert into seeded values (42);"
  assert_success

  # A relative --keep-db is relative to where the command runs.
  run ddev worktree add feature/smoke --keep-db "../$(basename "${DBDIR}")"
  assert_success
  run curl -sfk --retry 10 --retry-all-errors --retry-delay 1 "https://${PROJNAME}-smoke.ddev.site/"
  assert_success
  assert_output --partial "https://${PROJNAME}-smoke.ddev.site"
  run curl -sfk --retry 10 --retry-all-errors --retry-delay 1 "https://${PROJNAME}-smoke.ddev.site/assets/images/a.txt"
  assert_output "img"
  run cat "${WTDIR}/smoke/hookdb.txt"
  assert_output "42"
  run cat "${WTDIR}/smoke/hookvars.txt"
  assert_output "https://${PROJNAME}.ddev.site -> https://${PROJNAME}-smoke.ddev.site (${PROJNAME}-smoke)"
  run bash -c "ls '${DBDIR}'/*.sql.gz"
  assert_success

  run ddev worktree add feature/again --reuse-db --keep-db "${DBDIR}"
  assert_success
  assert_output --partial "Reusing ${DBDIR}/"
  run cat "${WTDIR}/again/hookdb.txt"
  assert_output "42"

  run ddev worktree rm smoke
  assert_success
  run ddev worktree rm again
  assert_success
  run ddev describe "${PROJNAME}"
  assert_success
}

@test "a project without a db container is not seeded" {
  set -eu -o pipefail
  run ddev config --omit-containers=db
  assert_success
  git add -A && git commit -qm nodb
  install_addon
  run ddev start -y
  assert_success

  run ddev worktree add feature/smoke
  assert_success
  assert_output --partial "omits the db container"
  run curl -sfk --retry 10 --retry-all-errors --retry-delay 1 "https://${PROJNAME}-smoke.ddev.site/"
  assert_success
}

@test "composer install is the default post-start; an empty conf setting turns it off" {
  set -eu -o pipefail
  echo '{}' > composer.json
  git add composer.json && git commit -qm composer
  install_addon
  run ddev start -y
  assert_success
  run ddev worktree add feature/smoke --no-db
  assert_success
  assert_output --partial "post-start: ddev composer install"
  run ddev worktree rm smoke --force
  assert_success

  echo 'WORKTREE_POST_START=()' >> .ddev/worktree.conf
  run ddev worktree add feature/smoke --no-db
  assert_success
  refute_output --partial "post-start:"
}

@test "an uncommitted .ddev/config.yaml gets a clear error" {
  set -eu -o pipefail
  install_addon
  git rm -q --cached .ddev/config.yaml && git commit -qm untrack
  run ddev worktree add feature/smoke --no-start
  assert_failure
  assert_output --partial ".ddev/config.yaml must be committed"
}

@test "a removed setting in worktree.conf gets a notice" {
  set -eu -o pipefail
  install_addon
  echo 'WORKTREE_UPLOAD_DIRS=(web/assets)' >> .ddev/worktree.conf
  run ddev worktree add feature/smoke --no-start
  assert_success
  assert_output --partial "WORKTREE_UPLOAD_DIRS is no longer used"
}

@test "a project without git gets a clear error" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  rm -rf .git
  run ddev worktree list
  assert_failure
  assert_output --partial "needs the project to be a git repository"
}

@test "re-running add-on get keeps the user's worktree.conf" {
  set -eu -o pipefail
  install_addon
  echo 'WORKTREE_POST_START=("echo custom")' >> .ddev/worktree.conf
  run ddev add-on get "${DIR}"
  assert_success
  run cat .ddev/worktree.conf
  assert_output --partial 'WORKTREE_POST_START=("echo custom")'
  assert_output --partial 'WORKTREE_CLONE_DIRS=(web/assets)'
  refute_output --partial '#ddev-generated'
}

# bats test_tags=release
@test "install from release" {
  set -eu -o pipefail
  run ddev add-on get "${GITHUB_REPO}"
  assert_success
  assert_file_exists .ddev/commands/host/worktree
}
