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
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true
  export CI=true
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  ddev delete -Oy "${PROJNAME}-smoke" >/dev/null 2>&1 || true
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

install_addon() {
  run ddev add-on get "${DIR}"
  assert_success
  assert_file_exists .ddev/commands/host/worktree
  assert_file_exists .ddev/worktree.conf
  cat >> .ddev/worktree.conf <<'EOF'
WORKTREE_CLONE_DIRS=(web/assets)
WORKTREE_UPLOAD_DIRS=(web/assets)
EOF
}

teardown() {
  set -eu -o pipefail
  ddev delete -Oy "${PROJNAME}-smoke" >/dev/null 2>&1 || true
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  if [ -n "${GITHUB_ENV:-}" ]; then
    [ -e "${GITHUB_ENV:-}" ] && echo "TESTDIR=${HOME}/tmp/${PROJNAME}" >> "${GITHUB_ENV}"
  else
    [ "${TESTDIR}" != "" ] && rm -rf "${TESTDIR}" "${WTDIR}"
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
  assert_output --partial "  - assets"
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
  assert_dir_exists "${TESTDIR}/.ddev"
}

@test "add starts its own project and seeds the database" {
  set -eu -o pipefail
  install_addon
  run ddev start -y
  assert_success

  run ddev worktree add feature/smoke
  assert_success
  run curl -sfk "https://${PROJNAME}-smoke.ddev.site/"
  assert_success
  assert_output --partial "https://${PROJNAME}-smoke.ddev.site"
  run curl -sfk "https://${PROJNAME}-smoke.ddev.site/assets/images/a.txt"
  assert_output "img"

  run ddev worktree rm smoke
  assert_success
  run ddev describe "${PROJNAME}"
  assert_success
}

@test "craftcms: local asset folders are detected from project config" {
  set -eu -o pipefail
  run ddev config --project-type=craftcms
  assert_success
  mkdir -p config/project web/assets/images web/assets/docs web/uploads
  echo 'doc' > web/assets/docs/d.txt
  printf 'ASSET_BASE="@webroot/uploads"\n' >> .env
  cat > config/project/project.yaml <<'EOF'
fs:
  images:
    settings:
      path: '@webroot/assets/images'
    type: craft\fs\Local
  docs:
    settings:
      path: "@root/web/assets/docs"
    type: craft\fs\Local
  uploads:
    settings:
      path: $ASSET_BASE
    type: craft\fs\Local
  remote:
    settings:
      path: '@webroot/missing'
    type: craft\fs\Local
EOF
  # Main already bind-mounts uploads, so the worktree must not list it again.
  printf 'upload_dirs:\n  - uploads\n' >> .ddev/config.yaml
  git add -A && git commit -qm craft
  run ddev add-on get "${DIR}"
  assert_success

  run ddev worktree config
  assert_success
  assert_output --partial "WORKTREE_CLONE_DIRS  [detected]"
  assert_output --partial "    web/assets"
  assert_output --partial "    web/uploads"
  refute_output --partial "web/assets/images"
  refute_output --partial "missing"
  assert_output --partial "ddev craft up --interactive=0"
  assert_output --partial "config/license.key"

  run ddev worktree add feature/smoke --no-start
  assert_success
  local wt="${WTDIR}/smoke"
  assert_file_exists "${wt}/web/assets/docs/d.txt"
  run cat "${wt}/.ddev/config.local.yaml"
  assert_output --partial "  - assets"
  refute_output --partial "  - uploads"
}

@test "build script is detected and run; an empty conf setting turns it off" {
  set -eu -o pipefail
  cat > package.json <<'EOF'
{
  "name": "fixture",
  "private": true,
  "scripts": {
    "dev": "echo dev",
    "production": "mkdir -p web/dist && echo built > web/dist/ok.txt"
  }
}
EOF
  git add package.json && git commit -qm pkg
  run ddev add-on get "${DIR}"
  assert_success

  run ddev worktree config
  assert_output --partial "ddev npm install"
  assert_output --partial "ddev npm run production"

  run ddev start -y
  assert_success
  run ddev worktree add feature/smoke --no-db
  assert_success
  assert_file_exists "${WTDIR}/smoke/web/dist/ok.txt"
  run ddev worktree rm smoke --force
  assert_success

  echo 'WORKTREE_POST_START=()' >> .ddev/worktree.conf
  run ddev worktree config
  assert_output --partial "WORKTREE_POST_START  [conf]"
  refute_output --partial "ddev npm run production"
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
