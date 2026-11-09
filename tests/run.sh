#!/bin/bash
# Test runner.   tests/run.sh [--gui] [name-filter]
#   --gui   also compile the SwiftUI front-end (slow; needs swiftc)
# Every test_* function runs in its own subshell and sandbox (see lib.sh).
cd "$(dirname "$0")" || exit 1
GUI=0; FILTER=""
for a in "$@"; do case "$a" in --gui) GUI=1 ;; *) FILTER="$a" ;; esac; done

source ./lib.sh
for f in ./test_*.sh; do source "$f"; done

pass=0; failed=0; skipped=0; failures=()
for t in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
  [[ "$t" == *"$FILTER"* ]] || continue
  if [[ "$t" == test_gui_* && $GUI -eq 0 ]]; then continue; fi
  out="$( ( new_sandbox; "$t" ) 2>&1 )"; rc=$?
  case $rc in
    0)  pass=$((pass+1)); printf '  ok    %s\n' "$t" ;;
    77) skipped=$((skipped+1)); printf '  skip  %s\n' "$t"; [[ -n "$out" ]] && echo "$out" ;;
    *)  failed=$((failed+1)); failures+=("$t"); printf '  FAIL  %s\n' "$t"; [[ -n "$out" ]] && echo "$out" ;;
  esac
done
echo
echo "passed: $pass   failed: $failed   skipped: $skipped"
[[ $failed -eq 0 ]]
