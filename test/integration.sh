#!/usr/bin/env bash
# End-to-end test: a real gopls drives the plugin through vim-lsp.
#
#   test/integration.sh
#
# Requires gopls on $PATH and vim-lsp checked out at ~/.vim/plugged/vim-lsp
# (override with CALLTREE_VIM_LSP).  Skips silently when gopls is missing.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

if ! command -v gopls >/dev/null 2>&1; then
  echo "skip: gopls not found"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/go.mod" <<'GOMOD'
module calltree/it

go 1.21
GOMOD
cat > "$work/main.go" <<'GOSRC'
package main

import "fmt"

func leaf() int { return 1 }

func mid() int { return leaf() }

func top() int { return mid() }

func third() int { return 3 }

func first() int { return 1 }

func second() int { return 2 }

func ordered() {
	_ = third()
	_ = first()
	_ = second()
	fmt.Println("done")
}

func main() {
	fmt.Println(top())
	ordered()
}
GOSRC

CALLTREE_TEST_DIR="$work" vim -Nu NONE -es -S "$here/integration.vim"

echo "--- tree ---"
cat "$work/result.txt"

grep -q '● mid' "$work/result.txt"
grep -q '▲ Callers' "$work/result.txt"
grep -q ' top ' "$work/result.txt"
grep -q ' main ' "$work/result.txt"
grep -q ' leaf ' "$work/result.txt"

# callees must be listed in the order they are called in the body
order=$(grep -E '▸ (third|first|second) ' "$work/ordered.txt" | sed 's/.*▸ \([a-z]*\).*/\1/' | tr '\n' ' ')
if [ "$order" != "third first second " ]; then
  echo "unexpected callee order: $order"
  exit 1
fi
echo "callee order: $order"

# preview follows the call site, not the definition
preview_line=$(sed -n 's/^preview_third=//p' "$work/preview.txt")
preview_text=$(sed -n "${preview_line}p" "$work/main.go")
case "$preview_text" in
  *'= third()'*) ;;
  *) echo "preview landed on: $preview_text"; exit 1 ;;
esac
echo "preview line $preview_line: $preview_text"

# K shows the whole function declaration in a floating window
grep -q 'func ordered() {' "$work/float.txt" || {
  echo "float popup missing the signature: $(head -3 "$work/float.txt" 2>/dev/null)"
  exit 1
}
grep -q '}' "$work/float.txt" || { echo "float popup missing the body end"; exit 1; }
echo "float popup: ok"

# q in the preview window closes the tree tab
grep -q '^qmap=<Plug>(calltree-close)' "$work/viewer-q.txt" || {
  echo "preview window q mapping: $(cat "$work/viewer-q.txt" 2>/dev/null)"
  exit 1
}
grep -q '^closed=1' "$work/viewer-q.txt" || {
  echo "q in the preview window did not close the tree tab"
  exit 1
}
echo "preview window q: ok"

# standard library nodes are painted with their own highlight group
grep -q 'calltree_stdlib' "$work/stdlib.txt" || {
  echo "stdlib node not highlighted: $(cat "$work/stdlib.txt" 2>/dev/null)"
  exit 1
}
echo "stdlib highlight: ok"
echo "integration: ok"
