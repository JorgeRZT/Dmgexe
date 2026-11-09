#!/bin/bash
# Test helpers. Bash 3.2 compatible (macOS /bin/bash).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/dmgexe.sh"
FIXTURES="$ROOT/tests/fixtures"

# --- assertions: report and leave the test's subshell on the first failure ----------------
fail() { echo "    FAIL: $*" >&2; exit 1; }
skip() { echo "    SKIP: $*" >&2; exit 77; }

assert_eq()           { [[ "$1" == "$2" ]] || fail "${3:-values differ}: expected [$2], got [$1]"; }
assert_contains()     { [[ "$1" == *"$2"* ]] || fail "${3:-text not found}: [$2] not in:"$'\n'"$1"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "${3:-unexpected text}: [$2] found in:"$'\n'"$1"; }
assert_file()         { [[ -f "$1" ]] || fail "missing file: $1"; }
assert_dir()          { [[ -d "$1" ]] || fail "missing folder: $1"; }
assert_missing()      { [[ ! -e "$1" ]] || fail "should not exist: $1"; }
assert_exec()         { [[ -x "$1" ]] || fail "not executable: $1"; }
assert_rc()           { [[ "$RC" == "$1" ]] || fail "exit code: expected $1, got $RC. Output:"$'\n'"$OUT"; }
assert_file_has()     { grep -qF -- "$2" "$1" 2>/dev/null || fail "[$2] not in $1:"$'\n'"$(cat "$1" 2>/dev/null)"; }
assert_file_lacks()   { ! grep -qF -- "$2" "$1" 2>/dev/null || fail "[$2] unexpectedly in $1"; }
count_in()            { grep -cF -- "$2" "$1" 2>/dev/null || true; }
assert_count()        { local n; n="$(count_in "$1" "$2")"; [[ "$n" == "$3" ]] || fail "[$2] appears $n times in $1, expected $3:"$'\n'"$(cat "$1" 2>/dev/null)"; }

# run CMD...: runs without aborting the test; result in $OUT (stdout+stderr) and $RC
run() { OUT="$("$@" 2>&1)"; RC=$?; }

# --- sandbox: every test gets its own HOME, cache, fake Wine and sample program ---------
new_sandbox() {
  SB="$(mktemp -d)"; SB="$(cd "$SB" && pwd -P)"
  export HOME="$SB/home" TMPDIR="$SB/tmp" DMGEXE_CACHE="$SB/cache"
  mkdir -p "$HOME" "$TMPDIR" "$DMGEXE_CACHE" "$SB/fakebin"
  cp "$FIXTURES"/fakebin/* "$SB/fakebin"/
  export PATH="$SB/fakebin:$PATH"
  export FAKE_WINE_LOG="$SB/wine.log" FAKE_OSA_LOG="$SB/osascript.log" FAKE_TRICKS_LOG="$SB/winetricks.log"
  : > "$FAKE_WINE_LOG"; : > "$FAKE_OSA_LOG"; : > "$FAKE_TRICKS_LOG"
  unset FAKE_WINEBOOT_FAIL DMGEXE_FOREGROUND DMGEXE_INSTALL_STAGE XDG_CACHE_HOME W_CACHE FAKE_TRICKS_RC FAKE_WINE_VERSION
  WINE="$SB/wine"; mkdir -p "$WINE"; cp -R "$FIXTURES/fake-wine/bin" "$WINE/bin"
  PROG="$SB/prog"; mkdir -p "$PROG/bin" "$PROG/data"
  echo "main"  > "$PROG/game.exe"
  echo "tool"  > "$PROG/bin/tool.exe"
  echo "data"  > "$PROG/data/level1.dat"
  echo "junk"  > "$PROG/.DS_Store"
  OUTD="$SB/out"
  SUPPORT_ROOT="$HOME/Library/Application Support"
  # Process discovery (--list-wine / --stop-wine / the "in use" check) looks at the whole machine. Limit it to this
  # sandbox, so a test can never see or stop the Wine programs that are really running.
  export DMGEXE_PROCESS_ROOT="$SB/"
  trap 'rm -rf "$SB"' EXIT
}

# dmg ARGS...: run the packager with the fake Wine and no network
dmg() { run /bin/bash "$SCRIPT" -w "$WINE" --no-d3dcompiler "$@"; }
# gen ARGS...: generate the sample program's app into $OUTD
gen() { dmg -e game.exe -d "$PROG" -n Demo -o "$OUTD" "$@"; }
APP_DEMO() { echo "$OUTD/Demo.app"; }
launcher_of() { echo "$1/Contents/MacOS/launcher"; }
# launch APP: runs the app's launcher synchronously (log goes to launcher.log)
launch() { run "$(launcher_of "$1")"; }
prefix_of() { echo "$SUPPORT_ROOT/$1/prefix"; }
# launcher_var APP NAME: value of a simple NAME=... assignment baked into the launcher
launcher_var() { ( eval "$(grep "^$2=" "$(launcher_of "$1")" | head -1)"; printf '%s' "${!2}" ); }

# fake_wine_process PREFIX [BINARY]: a long-lived process that Dmgexe takes for a Wine process of PREFIX:
# the executable is named like Wine's (wine64-preloader by default) and its working directory is in the prefix.
# Its pid is left in $BG. A copy of sleep, signed again so that macOS lets it run.
fake_wine_process() {
  local bin="${2:-wine64-preloader}"
  mkdir -p "$SB/fakewine/bin" "$1/drive_c/windows"
  if [[ ! -x "$SB/fakewine/bin/$bin" ]]; then cp /bin/sleep "$SB/fakewine/bin/$bin"; codesign --force -s - "$SB/fakewine/bin/$bin" >/dev/null 2>&1; fi
  ( trap - EXIT; cd "$1/drive_c/windows" && exec "$SB/fakewine/bin/$bin" 60 ) & BG=$!
  sleep 0.4
}
