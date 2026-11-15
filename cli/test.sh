#!/usr/bin/env bash
set -euo pipefail
cli_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bash "$cli_dir/build.sh"
for file in "$cli_dir"/dist/*.sh; do bash -n "$file"; done
# Lint assembled scripts so ShellCheck sees assignments across module boundaries.
shellcheck "$cli_dir/build.sh" "$cli_dir/test.sh" "$cli_dir/tests/systemd.sh" "$cli_dir"/dist/*.sh
bats "$cli_dir/tests/installer.bats"
