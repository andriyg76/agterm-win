#!/bin/bash
# Regenerates Resources/agterm.{ico,res,png} from agterm's own app icon. macOS only: the source is the Icon Composer
# document compiled into an agterm.app, which only the system renders. The .res is written here rather than by
# rc.exe so the Windows build needs no resource compiler.
set -euo pipefail
app=${1:-/Applications/agterm.app}
here=$(cd "$(dirname "$0")" && pwd)
out=$(cd "$here/../Resources" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swift "$here/make-icon-render.swift" "$app" "$work/render.png"
python3 -I "$here/make-icon.py" "$work/render.png" "$out"
ls -l "$out"
