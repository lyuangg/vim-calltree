#!/usr/bin/env bash
# PHP search provider: parser unit checks plus an end-to-end tree built from a
# throwaway project.  Requires ripgrep or ag on $PATH.
#
#   test/php.sh
#
# vim-lsp is needed for its URI/position helpers; override its location with
# CALLTREE_VIM_LSP.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

if ! command -v rg >/dev/null 2>&1 && ! command -v ag >/dev/null 2>&1; then
  echo "skip: neither rg nor ag found"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/src" "$work/vendor/pkg"

cat > "$work/composer.json" <<'JSON'
{"name": "calltree/php-fixture"}
JSON

cat > "$work/src/Svc.php" <<'PHP'
<?php
namespace App;

function leaf()
{
    return 1;
}

class Svc extends BaseSvc
{
    public function handle($x)
    {
        // helper() must not count as a call
        $s = "handle() in a string";
        return $this->helper($x) + leaf() + count($x);
    }

    private function helper($x)
    {
        return $x;
    }

    public function run($x)
    {
        $this->helper($x);
        parent::helper($x);
        return leaf();
    }

    public function withHeredoc()
    {
        $sql = <<<EOT
        select handle() { not code }
        EOT;
        $o = new \App\Foo();
        return leaf();
    }
}

abstract class BaseSvc
{
    abstract protected function helper($x);
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
        return $svc;
    }
}
PHP

cat > "$work/src/Notes.php" <<'PHP'
<?php
// handle() in a comment
/* $svc->handle(2); */
$doc = 'handle(3)';
PHP

cat > "$work/src/Cycle.php" <<'PHP'
<?php
function ping()
{
    return pong();
}

function pong()
{
    return ping();
}
PHP

cat > "$work/src/Hot.php" <<'PHP'
<?php
function hot()
{
    return 1;
}
PHP

cat > "$work/src/HotCallers.php" <<'PHP'
<?php
function hot1() { return hot(); }
function hot2() { return hot(); }
function hot3() { return hot(); }
function hot4() { return hot(); }
PHP

cat > "$work/vendor/pkg/Lib.php" <<'PHP'
<?php
function handle($x) { return $x; }
function vendorCaller() { return handle(5); }
PHP

cat > "$work/src/Static.php" <<'PHP'
<?php
namespace App;

class StaticModel
{
    public static function boot()
    {
        return 1;
    }

    private function secret()
    {
        return 2;
    }

    public function callSecret()
    {
        return $this->secret();
    }
}

class OtherModel
{
    public static function boot()
    {
        return 3;
    }

    public function callSecret()
    {
        $x = new StaticModel();
        return $x->secret();
    }
}

function useStatic()
{
    return StaticModel::boot();
}

function useOther()
{
    return OtherModel::boot();
}
PHP

fail=0
check() {
  if ! grep -q "$1" "$work/$2"; then
    echo "FAIL $2: $1"
    cat "$work/$2"
    fail=1
  fi
}

check_all() {
  check '^ok   parser finds 6 definitions' unit.txt
  check '^ok   parser assigns classes' unit.txt
  check '^ok   parser ignores comments, strings and heredocs' unit.txt
  check '^ok   parser skips new expressions' unit.txt
  check '^ok   parser keeps utf-16 columns' unit.txt

  check '● handle' result.txt
  check '▲ Callers (1)' result.txt
  check ' run ' result.txt
  check ' helper ' result.txt
  check ' leaf ' result.txt
  check '· count' result.txt

  check '● handle' callsite.txt
  check ' run ' callsite.txt

  helper_lines=$(grep -c '▸ helper  src/Svc.php:' "$work/run.txt" || true)
  if [ "$helper_lines" != "2" ]; then
    echo "FAIL run.txt: expected two helper definitions, got $helper_lines"
    cat "$work/run.txt"
    fail=1
  fi
  check '▸ leaf  src/Svc.php:' run.txt

  check '↻ ping' cycle.txt

  check '…+?' cap.txt

  # Callers must be class-aware: OtherModel::boot() is not StaticModel::boot().
  check 'useStatic' static_callers.txt
  if grep -q 'useOther' "$work/static_callers.txt"; then
    echo "FAIL static_callers.txt: OtherModel::boot leaked in"
    cat "$work/static_callers.txt"
    fail=1
  fi

  # A private method is only reachable from its own class, not another class
  # in the same file.
  secret_callers=$(grep -c 'callSecret' "$work/secret_callers.txt" || true)
  if [ "$secret_callers" != "1" ]; then
    echo "FAIL secret_callers.txt: expected one caller, got $secret_callers"
    cat "$work/secret_callers.txt"
    fail=1
  fi
}

CALLTREE_TEST_DIR="$work" vim -Nu NONE -es -S "$here/php.vim"
check_all

# The ag fallback is a different command line; exercise it when installed.
if command -v ag >/dev/null 2>&1; then
  CALLTREE_PHP_ENGINE=ag CALLTREE_TEST_DIR="$work" \
    vim -Nu NONE -es -S "$here/php.vim"
  check_all
fi

if [ "$fail" -ne 0 ]; then
  echo "php: failed"
  exit 1
fi
echo "php: ok"
