# Running Wine processes: how they are found, listed and stopped, and the "in use" check built on them.
# The processes are copies of sleep named like Wine's executables (see fake_wine_process in lib.sh), and
# DMGEXE_PROCESS_ROOT (set for every test) keeps the search inside the test's sandbox: these tests can never
# see, and so never stop, the Wine programs that are really running on the machine.

# Never "kill ${BG:-0}": with BG unset that becomes "kill 0", which signals the whole process group (the test runner).
cleanup_bg() {
  local p
  for p in "${BG:-}" "${BG2:-}"; do [[ "$p" =~ ^[0-9]+$ ]] && kill "$p" 2>/dev/null; done
  wait 2>/dev/null; true
}
alive() { kill -0 "$1" 2>/dev/null && echo 1 || echo 0; }
fake_in_dir_with_fd() { # fake_in_dir_with_fd CWD FILE: a Wine-looking process in CWD holding FILE open (pid in $BG)
  mkdir -p "$SB/fakewine/bin" "$1"
  cp /bin/sleep "$SB/fakewine/bin/wine64-preloader"; codesign --force -s - "$SB/fakewine/bin/wine64-preloader" >/dev/null 2>&1
  ( trap - EXIT; cd "$1" && exec 9< "$2" && exec "$SB/fakewine/bin/wine64-preloader" 60 ) & BG=$!
  sleep 0.4
}

test_the_search_is_limited_to_the_sandbox() {
  [[ "$DMGEXE_PROCESS_ROOT" == "$SB/" ]] || fail "DMGEXE_PROCESS_ROOT must point at the sandbox, it is [$DMGEXE_PROCESS_ROOT]"
}

test_stop_wine_refuses_to_run_without_the_sandbox_limit() {
  local out rc
  out="$(env -u DMGEXE_PROCESS_ROOT /bin/bash -c 'source "'"$ROOT"'/tests/lib.sh"; source "'"$ROOT"'/tests/test_storage.sh"; storage --stop-wine all' 2>&1)"; rc=$?
  [[ $rc -eq 99 ]] || fail "the test helper must refuse (rc=$rc): $out"
}

test_no_wine_processes_lists_nothing() {
  storage --list-wine; assert_rc 0
  assert_eq "$OUT" ""
}

test_a_wine_process_is_listed_with_its_app() {
  gen; launch "$(APP_DEMO)"
  fake_wine_process "$(prefix_of Demo)"
  storage --list-wine; cleanup_bg
  assert_rc 0
  local r; r="$(printf '%s\n' "$OUT" | awk -F'\t' '$1 == "wine"')"
  assert_eq "$(field "$r" 2)" "$BG"
  assert_eq "$(field "$r" 3)" "Demo"
  [[ -n "$(field "$r" 4)" ]] || fail "running time missing: $r"
  assert_contains "$(field "$r" 5)" "60"
}

test_the_in_use_check_does_not_depend_on_the_environment() {
  # regression: Wine runs translated by Rosetta and macOS hides its environment, so WINEPREFIX cannot be used
  gen; launch "$(APP_DEMO)"
  ( unset WINEPREFIX; fake_wine_process "$(prefix_of Demo)"; echo "$BG" > "$SB/bg" )
  BG="$(cat "$SB/bg")"
  storage --delete-prefix Demo; local rc=$RC out="$OUT"
  cleanup_bg
  [[ $rc -eq 1 ]] || fail "should refuse while a Wine process runs there: rc=$rc $out"
  assert_contains "$out" "in use"
  assert_dir "$(prefix_of Demo)"
}

test_a_process_outside_any_prefix_is_listed_as_unknown() {
  fake_wine_process "$SB/elsewhere"
  storage --list-wine; cleanup_bg
  assert_contains "$OUT" "(unknown)"
}

test_processes_that_are_not_wine_are_ignored() {
  gen; launch "$(APP_DEMO)"
  ( trap - EXIT; cd "$(prefix_of Demo)/drive_c/windows" && exec /bin/sleep 60 ) & BG=$!
  sleep 0.3
  storage --list-wine; cleanup_bg
  assert_eq "$OUT" ""
}

test_a_process_is_matched_by_a_file_it_has_open_in_the_prefix() {
  gen; launch "$(APP_DEMO)"
  fake_in_dir_with_fd "$SB/elsewhere" "$(prefix_of Demo)/system.reg"
  storage --list-wine; cleanup_bg
  assert_eq "$(field "$(printf '%s\n' "$OUT" | head -1)" 3)" "Demo"
}

test_a_process_is_matched_by_its_wineserver_directory() {
  gen; launch "$(APP_DEMO)"
  local px key d; px="$(prefix_of Demo)"
  key="server-$(printf '%x-%x' $(stat -f '%d %i' "$px"))"
  d="$SB/wineserver-dirs/$key"; mkdir -p "$d"; echo map > "$d/tmpmap-1"
  fake_in_dir_with_fd "$SB/elsewhere" "$d/tmpmap-1"
  storage --list-wine; cleanup_bg
  assert_eq "$(field "$(printf '%s\n' "$OUT" | head -1)" 3)" "Demo"
}

test_processes_are_grouped_by_their_own_prefix() {
  gen; dmg -e game.exe -d "$PROG" -n Other -o "$OUTD"
  launch "$(APP_DEMO)"; launch "$OUTD/Other.app"
  fake_wine_process "$(prefix_of Demo)"; BG2=$BG
  fake_wine_process "$(prefix_of Other)"
  storage --list-wine
  local a b; a="$(printf '%s\n' "$OUT" | awk -F'\t' -v p="$BG2" '$2 == p')"; b="$(printf '%s\n' "$OUT" | awk -F'\t' -v p="$BG" '$2 == p')"
  cleanup_bg
  assert_eq "$(field "$a" 3)" "Demo"
  assert_eq "$(field "$b" 3)" "Other"
}

# --- stopping ------------------------------------------------------------------------------

test_stop_wine_stops_only_that_app() {
  gen; dmg -e game.exe -d "$PROG" -n Other -o "$OUTD"
  launch "$(APP_DEMO)"; launch "$OUTD/Other.app"
  fake_wine_process "$(prefix_of Demo)"; BG2=$BG
  fake_wine_process "$(prefix_of Other)"
  storage --stop-wine Demo; local rc=$RC out="$OUT"
  sleep 0.3
  local demo other; demo="$(alive "$BG2")"; other="$(alive "$BG")"
  cleanup_bg
  assert_eq "$rc" 0
  assert_eq "$demo" 0 "Demo's process should be gone"
  assert_eq "$other" 1 "Other's process must keep running"
  assert_contains "$out" "stopped 1 process"
}

test_stop_wine_all() {
  gen; launch "$(APP_DEMO)"
  fake_wine_process "$(prefix_of Demo)"; BG2=$BG
  fake_wine_process "$SB/elsewhere"
  storage --stop-wine all; local rc=$RC
  sleep 0.3
  local a b; a="$(alive "$BG2")"; b="$(alive "$BG")"
  cleanup_bg
  assert_eq "$rc" 0; assert_eq "$a" 0; assert_eq "$b" 0
}

test_stop_wine_one_pid() {
  gen; launch "$(APP_DEMO)"
  fake_wine_process "$(prefix_of Demo)"; BG2=$BG
  fake_wine_process "$(prefix_of Demo)"
  storage --stop-wine "pid:$BG2"; local rc=$RC
  sleep 0.3
  local a b; a="$(alive "$BG2")"; b="$(alive "$BG")"
  cleanup_bg
  assert_eq "$rc" 0; assert_eq "$a" 0; assert_eq "$b" 1
}

test_stop_wine_never_touches_a_process_that_is_not_wine() {
  ( trap - EXIT; exec /bin/sleep 60 ) & BG=$!
  sleep 0.2
  storage --stop-wine "pid:$BG"; local rc=$RC
  storage --stop-wine all
  local a; a="$(alive "$BG")"
  cleanup_bg
  [[ $rc -ne 0 ]] || fail "pid:N of a non-Wine process must be refused"
  assert_eq "$a" 1
}

test_stop_wine_unknown_target() {
  storage --stop-wine Nobody
  assert_rc 1
  assert_contains "$OUT" "no Wine process matches"
}

test_stop_wine_asks_the_wineserver_first() {
  gen; launch "$(APP_DEMO)"
  mkdir -p "$SB/fakewine/bin"; cp "$FIXTURES/fake-wine/bin/wineserver" "$SB/fakewine/bin/wineserver"
  fake_wine_process "$(prefix_of Demo)"
  : > "$FAKE_WINE_LOG"
  storage --stop-wine Demo; cleanup_bg
  assert_rc 0
  assert_file_has "$FAKE_WINE_LOG" "wineserver -k prefix=$(prefix_of Demo)"
}

test_stop_wine_kills_what_ignores_the_polite_request() {
  gen; launch "$(APP_DEMO)"
  mkdir -p "$SB/fakewine/bin" "$(prefix_of Demo)/drive_c/windows"
  cp /bin/sleep "$SB/fakewine/bin/wine64-preloader"; codesign --force -s - "$SB/fakewine/bin/wine64-preloader" >/dev/null 2>&1
  ( trap '' TERM; trap - EXIT; cd "$(prefix_of Demo)/drive_c/windows" && exec "$SB/fakewine/bin/wine64-preloader" 60 ) & BG=$!
  sleep 0.4
  storage --stop-wine Demo; local rc=$RC
  local a; a="$(alive "$BG")"
  cleanup_bg
  assert_eq "$rc" 0
  assert_eq "$a" 0 "a process that ignores TERM must be killed"
}

test_after_stopping_the_prefix_can_be_deleted() {
  gen; launch "$(APP_DEMO)"
  fake_wine_process "$(prefix_of Demo)"
  storage --delete-prefix Demo; assert_rc 1
  storage --stop-wine Demo; assert_rc 0
  storage --delete-prefix Demo; cleanup_bg
  assert_rc 0
  assert_missing "$(prefix_of Demo)"
}

test_help_documents_process_commands() {
  run /bin/bash "$SCRIPT" --help
  assert_contains "$OUT" "--list-wine"
  assert_contains "$OUT" "--stop-wine"
}
