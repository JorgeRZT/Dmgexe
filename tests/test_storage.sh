# Storage: list / delete prefixes and winetricks downloads.

# fake_cache VERB...: winetricks downloads in the (sandboxed) default cache
fake_cache() {
  local v; for v in "$@"; do mkdir -p "$HOME/.cache/winetricks/$v"; head -c 20000 /dev/zero > "$HOME/.cache/winetricks/$v/setup.exe"; done
}
storage() {
  # safety net: stopping processes must never run without the sandbox limit
  case " $* " in *" --stop-wine "*) [[ -n "${DMGEXE_PROCESS_ROOT:-}" ]] || { echo "REFUSING: DMGEXE_PROCESS_ROOT is not set" >&2; exit 99; };; esac
  run /bin/bash "$SCRIPT" "$@"
}
# busy_in PREFIX: a process that looks like Wine's to Dmgexe (a wine64-preloader whose working directory is
# inside the prefix); pid in $BG. A copy of sleep, because macOS hides the environment of its own binaries.
busy_in() { fake_wine_process "$1"; }
stop_busy() { kill "$BG" 2>/dev/null; wait "$BG" 2>/dev/null; }
# row KIND NAME: the listing line of a prefix/cache entry
row() { printf '%s\n' "$OUT" | awk -F'\t' -v k="$1" -v n="$2" '$1 == k && $2 == n'; }
field() { printf '%s' "$1" | cut -f"$2"; }

test_list_prefixes_is_empty_on_a_fresh_machine() {
  storage --list-prefixes
  assert_rc 0
  assert_eq "$OUT" ""
}

test_list_prefixes_shows_apps_after_their_first_launch() {
  gen; launch "$(APP_DEMO)"
  storage --list-prefixes; assert_rc 0
  local r; r="$(row prefix Demo)"
  [[ -n "$r" ]] || fail "Demo not listed: $OUT"
  assert_eq "$(field "$r" 3)" "$(prefix_of Demo)"
  [[ "$(field "$r" 4)" =~ ^[0-9]+$ ]] || fail "size should be a number of KB: $r"
  assert_eq "$(field "$r" 5)" ""
}

test_list_prefixes_reports_the_installed_winetricks_verbs() {
  gen; launch "$(APP_DEMO)"
  printf 'vcrun2008\nd3dx9\nvcrun2008\n' > "$(prefix_of Demo)/winetricks.log"
  storage --list-prefixes
  assert_eq "$(field "$(row prefix Demo)" 5)" "vcrun2008,d3dx9"
}

test_list_prefixes_finds_prefixes_on_other_volumes() {
  gen --prefix-dir "$SB/ext/Demo"; launch "$(APP_DEMO)"
  storage --list-prefixes
  assert_eq "$(field "$(row prefix Demo)" 3)" "$SB/ext/Demo"
}

test_list_prefixes_ignores_folders_that_are_not_apps() {
  mkdir -p "$SUPPORT_ROOT/Dmgexe/covers" "$SUPPORT_ROOT/SomethingElse"; echo x > "$SUPPORT_ROOT/Dmgexe/library.json"
  gen; launch "$(APP_DEMO)"
  storage --list-prefixes
  assert_eq "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "1"
}

test_list_prefixes_skips_a_disconnected_drive() {
  gen --prefix-dir "$SB/ext/Demo"; launch "$(APP_DEMO)"
  rm -rf "$SB/ext"
  storage --list-prefixes; assert_rc 0
  assert_eq "$OUT" ""
}

test_launcher_records_where_its_prefix_is() {
  gen; launch "$(APP_DEMO)"
  assert_eq "$(cat "$SUPPORT_ROOT/Demo/.prefix-path")" "$(prefix_of Demo)"
}

# --- cache -----------------------------------------------------------------------------------

test_list_cache() {
  fake_cache vcrun2008 d3dx9
  echo stray > "$HOME/.cache/winetricks/loose-file.txt"
  storage --list-cache; assert_rc 0
  [[ -n "$(row cache vcrun2008)" && -n "$(row cache d3dx9)" ]] || fail "verbs missing: $OUT"
  assert_not_contains "$OUT" "loose-file"
  [[ "$(field "$(row cache d3dx9)" 4)" -ge 16 ]] || fail "size should be about 20 KB"
}

test_list_cache_reads_both_default_locations() {
  fake_cache a
  mkdir -p "$HOME/Library/Caches/winetricks/b"; echo x > "$HOME/Library/Caches/winetricks/b/f"
  storage --list-cache
  [[ -n "$(row cache a)" && -n "$(row cache b)" ]] || fail "$OUT"
}

test_list_cache_honours_w_cache() {
  mkdir -p "$SB/mycache/zzz"; echo x > "$SB/mycache/zzz/f"
  W_CACHE="$SB/mycache" storage --list-cache
  [[ -n "$(row cache zzz)" ]] || fail "$OUT"
}

test_delete_one_cached_verb() {
  fake_cache vcrun2008 d3dx9
  storage --delete-cache vcrun2008; assert_rc 0
  assert_missing "$HOME/.cache/winetricks/vcrun2008"
  assert_dir "$HOME/.cache/winetricks/d3dx9"
}

test_delete_all_cached_verbs_keeps_the_cache_folder() {
  fake_cache a b
  echo stray > "$HOME/.cache/winetricks/loose-file.txt"
  storage --delete-cache all; assert_rc 0
  assert_missing "$HOME/.cache/winetricks/a"
  assert_missing "$HOME/.cache/winetricks/b"
  assert_dir "$HOME/.cache/winetricks"
  assert_file "$HOME/.cache/winetricks/loose-file.txt"
}

test_delete_all_with_no_cache_is_not_an_error() {
  storage --delete-cache all
  assert_rc 0
}

test_delete_unknown_cached_verb_fails() {
  fake_cache a
  storage --delete-cache nope
  assert_rc 1
  assert_contains "$OUT" "no cached downloads"
}

test_delete_cache_rejects_paths() {
  fake_cache a
  mkdir -p "$SB/victim"; echo keep > "$SB/victim/f"
  local v
  for v in "../victim" ".." "." "a/b" "/etc"; do
    storage --delete-cache "$v"
    [[ $RC -ne 0 ]] || fail "[$v] accepted"
  done
  assert_file "$SB/victim/f"
  assert_dir "$HOME/.cache/winetricks/a"
}

# --- prefixes --------------------------------------------------------------------------------

test_delete_prefix_removes_it_and_its_markers() {
  gen --winver 10 --retina --winetricks "vcrun2008"; launch "$(APP_DEMO)"
  assert_dir "$(prefix_of Demo)"
  storage --delete-prefix Demo; assert_rc 0
  assert_missing "$(prefix_of Demo)"
  assert_missing "$SUPPORT_ROOT/Demo/.winetricks-done"
  assert_missing "$SUPPORT_ROOT/Demo/.retina-1"
  assert_missing "$SUPPORT_ROOT/Demo/.winver-win10"
  assert_file "$SUPPORT_ROOT/Demo/launcher.log"
}

test_the_app_rebuilds_a_deleted_prefix_from_scratch() {
  gen --winver 10 --winetricks "vcrun2008" --no-template; launch "$(APP_DEMO)"
  storage --delete-prefix Demo; assert_rc 0
  : > "$FAKE_WINE_LOG"; : > "$FAKE_TRICKS_LOG"
  launch "$(APP_DEMO)"; assert_rc 0
  assert_file "$(prefix_of Demo)/system.reg"
  assert_file_has "$FAKE_WINE_LOG" "wine wineboot --init"
  assert_file_has "$FAKE_WINE_LOG" "/v Version /t REG_SZ /d win10"
  assert_file_has "$FAKE_TRICKS_LOG" "winetricks -q vcrun2008"
}

test_delete_prefix_on_another_volume() {
  gen --prefix-dir "$SB/ext/Demo"; launch "$(APP_DEMO)"
  storage --delete-prefix Demo; assert_rc 0
  assert_missing "$SB/ext/Demo"
  assert_dir "$SB/ext"
}

test_delete_prefix_leaves_the_program_files_alone() {
  gen --link; launch "$(APP_DEMO)"
  storage --delete-prefix Demo
  assert_file "$PROG/game.exe"
  assert_file "$PROG/data/level1.dat"
}

test_delete_prefix_unknown_app() {
  storage --delete-prefix Nobody
  assert_rc 1
  assert_contains "$OUT" "no prefix found"
}

test_delete_prefix_rejects_odd_names() {
  gen; launch "$(APP_DEMO)"
  local n
  for n in "../Demo" "a/b" ".." "."; do
    storage --delete-prefix "$n"
    [[ $RC -ne 0 ]] || fail "[$n] accepted"
  done
  assert_dir "$(prefix_of Demo)"
}

test_delete_prefix_refuses_what_is_not_a_windows_prefix() {
  gen --prefix-dir "$SB/ext/Demo"; launch "$(APP_DEMO)"
  rm -rf "$SB/ext/Demo"; mkdir -p "$SB/ext/Demo"; echo precious > "$SB/ext/Demo/notes.txt"
  storage --delete-prefix Demo
  assert_rc 1
  assert_contains "$OUT" "does not look like a Windows prefix"
  assert_file "$SB/ext/Demo/notes.txt"
}

test_delete_prefix_reports_a_disconnected_drive() {
  gen --prefix-dir "$SB/ext/Demo"; launch "$(APP_DEMO)"
  rm -rf "$SB/ext"
  storage --delete-prefix Demo
  assert_rc 1
  assert_contains "$OUT" "Is its drive connected?"
}

test_delete_prefix_refuses_while_it_is_in_use() {
  gen; launch "$(APP_DEMO)"
  busy_in "$(prefix_of Demo)"
  storage --delete-prefix Demo
  stop_busy
  assert_rc 1
  assert_contains "$OUT" "in use"
  assert_dir "$(prefix_of Demo)"
}

test_delete_prefix_works_once_nothing_runs_in_it() {
  gen; launch "$(APP_DEMO)"
  busy_in "$(prefix_of Demo)"; stop_busy
  storage --delete-prefix Demo
  assert_rc 0
}

test_deleting_a_prefix_removes_an_installed_program() {
  make_installer "install Program Files/FakeApp/FakeApp.exe"
  inst; assert_rc 0
  storage --delete-prefix FakeApp; assert_rc 0
  launch "$(APP_FAKE)"
  assert_rc 1                                              # the app says it has to be installed again
  assert_file_has "$FAKE_OSA_LOG" "Cannot find the program at"
}

test_storage_commands_need_no_exe() {
  storage --list-prefixes; assert_rc 0
  storage --list-cache;    assert_rc 0
}

test_help_documents_storage() {
  run /bin/bash "$SCRIPT" --help
  assert_contains "$OUT" "--delete-prefix"
  assert_contains "$OUT" "--list-cache"
}

# --- regression: the commands must work with many prefixes ----------------------------------
# The lookups "each_prefix | awk '... {print; exit}'" made awk quit early; with enough prefixes the writer got
# SIGPIPE and, with pipefail, the whole command died silently (no output, no deletion).

many_prefixes() {
  local i n
  for i in $(seq -w 1 80); do
    n="App$i"; mkdir -p "$SUPPORT_ROOT/$n/prefix/drive_c"; : > "$SUPPORT_ROOT/$n/prefix/system.reg"
  done
}

test_delete_prefix_works_with_many_prefixes() {
  many_prefixes
  storage --delete-prefix App01; assert_rc 0
  assert_contains "$OUT" "deleted:"
  assert_missing "$SUPPORT_ROOT/App01/prefix"
  assert_dir "$SUPPORT_ROOT/App02/prefix"
  storage --delete-prefix App80; assert_rc 0
  assert_missing "$SUPPORT_ROOT/App80/prefix"
}

test_list_prefixes_works_with_many_prefixes() {
  many_prefixes
  storage --list-prefixes; assert_rc 0
  assert_eq "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" 80
}

test_list_wine_works_with_many_prefixes() {
  many_prefixes
  fake_wine_process "$SUPPORT_ROOT/App01/prefix"
  storage --list-wine; cleanup_bg 2>/dev/null
  assert_rc 0
  assert_eq "$(field "$(printf '%s\n' "$OUT" | head -1)" 3)" "App01"
}

test_stop_wine_works_with_many_prefixes() {
  many_prefixes
  fake_wine_process "$SUPPORT_ROOT/App01/prefix"
  storage --stop-wine App01; local rc=$RC
  kill -0 "$BG" 2>/dev/null && { kill "$BG"; fail "the process should have been stopped"; }
  assert_eq "$rc" 0
}
