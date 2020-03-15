#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
export GIT_DIR=$HOME/checkouts/rust/.git
git -C $GIT_DIR fetch origin
exec $(nix-build ~/config/pkgs -A rustc-commit-db --no-out-link)/bin/rustc-commit-db update --directory $PWD
