#!/bin/sh
# Builds every full program in the guides, so an API change can't silently break the docs.
# Code blocks titled like files (```zig title="src/main.zig") are written out page by page.
set -eu
cd "$(dirname "$0")"
for page in $(grep -rl 'title="src/main.zig"' ../docs | sort); do
    echo "== $page"
    rm -rf src && mkdir src
    python3 - "$page" <<'PY'
import os, re, sys
text = open(sys.argv[1]).read()
for name, code in re.findall(r'```\w+ title="([^"]+)"\n(.*?)```', text, re.S):
    path = name if name.startswith("src/") else os.path.join("src", name)
    open(path, "w").write(code)
PY
    # DXC is the recommended compiler; glslangValidator's HLSL frontend (-D) is the fallback.
    for shader in src/*.vert.hlsl src/*.frag.hlsl; do
        [ -e "$shader" ] || continue
        stage=${shader%.hlsl}; stage=${stage##*.}
        if command -v dxc >/dev/null; then
            dxc -spirv -T "$([ "$stage" = vert ] && echo vs || echo ps)_6_0" -E main "$shader" -Fo "${shader%.hlsl}.spv"
        else
            glslangValidator -V -D -e main -S "$stage" -o "${shader%.hlsl}.spv" "$shader"
        fi
    done
    zig build
done
