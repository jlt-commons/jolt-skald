#!/usr/bin/env bash
# `jolt build` every example as a static binary, check it carries no dynamic
# dependency on SDL3 or the shim, then run the whole e2e suite against the
# binaries (each run from its own scratch directory, away from the project).
# Needs native/static/libskald_jolt_all.a: run `jolt native-static` first.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/.."
[ -f "$root/native/static/libskald_jolt_all.a" ] || {
  echo "SKIP: native/static/libskald_jolt_all.a missing — run: SDL3_STATIC_DIR=… jolt native-static"; exit 0; }
out="$(mktemp -d)"; trap 'rm -rf "$out"' EXIT
cd "$root/examples"
for ns in counter todo gallery stress widgets data studio; do
  echo "== build examples.$ns"
  jolt build -m "examples.$ns" -o "$out/$ns" 2>&1 | grep -E "wrote|rror|loaded at runtime" || true
  [ -x "$out/$ns" ] || { echo "FAIL: no binary"; exit 1; }
  if ldd "$out/$ns" | grep -E "SDL3|skald_jolt|X11"; then echo "FAIL: dynamic dependency above"; exit 1; fi
  echo "   $(du -h "$out/$ns" | cut -f1), deps: $(ldd "$out/$ns" | awk '{print $1}' | grep -v vdso | tr '\n' ' ')"
done
rm -rf "$out"/*.build
cp -r "$root/examples/resources" "$out/"   # the widgets example loads resources/sample.png
fail=0
for t in e2e_counter e2e_todo e2e_gallery e2e_stress e2e_widgets e2e_data e2e_studio; do
  echo "== $t (binary)"
  res=$(XH_BIN_DIR="$out" timeout 180 bash "$here/$t.sh" 2>&1); rc=$?
  if [ $rc = 0 ]; then echo "$res" | tail -2; else echo "$res" | tail -25; fail=1; fi
done
[ $fail = 0 ] && echo "ALL BINARY TESTS PASSED" || { echo "SOME FAILED"; exit 1; }
