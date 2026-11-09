#!/usr/bin/env bash
# PHP + language server: definition for the root and references for callers.
# Requires intelephense on $PATH; skips otherwise.
#
#   test/php_lsp.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

if ! command -v intelephense >/dev/null 2>&1; then
  echo "skip: intelephense not found"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/src"

cat > "$work/composer.json" <<'JSON'
{"name": "calltree/php-lsp-fixture", "autoload": {"psr-4": {"App\\": "src/"}}}
JSON

cat > "$work/src/Svc.php" <<'PHP'
<?php
namespace App;

function leaf()
{
    return 1;
}

class Svc
{
    public function handle($x)
    {
        return $this->helper($x) + leaf();
    }

    private function helper($x)
    {
        return $x;
    }
}
PHP

cat > "$work/src/Controller.php" <<'PHP'
<?php
namespace App;

class Controller
{
    public function run()
    {
        $svc = new Svc();
        $svc->handle(1);
    }
}

function bootstrap()
{
    return \App\leaf();
}
PHP

CALLTREE_TEST_DIR="$work" vim -Nu NONE -es -S "$here/php_lsp.vim"

fail=0
check() {
  if ! grep -q "$1" "$work/$2"; then
    echo "FAIL $2: $1"
    cat "$work/$2"
    fail=1
  fi
}

check '● leaf' leaf.txt
check '▲ Callers (2)' leaf.txt
check ' bootstrap ' leaf.txt
check ' handle ' leaf.txt

check '● handle' handle.txt
check '▲ Callers (1)' handle.txt
check ' run ' handle.txt
check ' helper ' handle.txt
check ' leaf ' handle.txt

if [ "$fail" -ne 0 ]; then
  echo "php_lsp: failed"
  exit 1
fi
echo "php_lsp: ok"
