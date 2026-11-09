# The global folder for new prefixes ("bottles"): --set-prefix-root / --get-prefix-root / --move-prefix,
# and how the launcher and the script agree on where a prefix is.

ROOTD() { echo "$SB/ext/Bottles"; }       # stands in for /Volumes/Disk/Bottles
CONFIG_F() { echo "$SUPPORT_ROOT/Dmgexe/config"; }

test_no_root_by_default() {
  storage --get-prefix-root; assert_rc 0
  assert_eq "$OUT" ""
}

test_set_and_get_the_root() {
  storage --set-prefix-root "$(ROOTD)"; assert_rc 0
  assert_dir "$(ROOTD)"
  assert_file_has "$(CONFIG_F)" "prefix_root=$(ROOTD)"
  storage --get-prefix-root
  assert_eq "$OUT" "$(ROOTD)"
}

test_set_root_accepts_relative_paths_and_trailing_slash() {
  mkdir -p "$SB/cwd"
  ( cd "$SB/cwd" && /bin/bash "$SCRIPT" --set-prefix-root rel/bottles/ >/dev/null )
  storage --get-prefix-root
  assert_eq "$OUT" "$SB/cwd/rel/bottles"
}

test_reset_root_to_default() {
  storage --set-prefix-root "$(ROOTD)"
  storage --set-prefix-root default; assert_rc 0
  storage --get-prefix-root
  assert_eq "$OUT" ""
  storage --set-prefix-root "$(ROOTD)"
  storage --set-prefix-root ""; assert_rc 0
  storage --get-prefix-root
  assert_eq "$OUT" ""
}

test_set_root_on_an_unavailable_volume_fails_and_keeps_the_old_one() {
  storage --set-prefix-root "$(ROOTD)"
  : > "$SB/notadir"
  storage --set-prefix-root "$SB/notadir/Bottles"
  assert_rc 1
  assert_contains "$OUT" "is the volume connected?"
  storage --get-prefix-root
  assert_eq "$OUT" "$(ROOTD)"
}

# --- where prefixes are created --------------------------------------------------------------

test_new_apps_get_their_prefix_in_the_root() {
  storage --set-prefix-root "$(ROOTD)"
  gen; launch "$(APP_DEMO)"; assert_rc 0
  assert_file "$(ROOTD)/Demo/prefix/system.reg"
  assert_missing "$(prefix_of Demo)"                                     # not in Application Support
  assert_file "$SUPPORT_ROOT/Demo/launcher.log"                          # only the small log stays
  assert_file_has "$FAKE_WINE_LOG" "env WINEPREFIX=$(ROOTD)/Demo/prefix"
  assert_eq "$(cat "$SUPPORT_ROOT/Demo/.prefix-path")" "$(ROOTD)/Demo/prefix"
}

test_without_a_root_nothing_changes() {
  gen; launch "$(APP_DEMO)"
  assert_file "$(prefix_of Demo)/system.reg"
}

test_the_root_is_read_at_launch_not_when_generating() {
  gen                                                                     # generated before the root exists
  storage --set-prefix-root "$(ROOTD)"
  launch "$(APP_DEMO)"; assert_rc 0
  assert_file "$(ROOTD)/Demo/prefix/system.reg"
}

test_an_existing_prefix_stays_where_it_is_when_the_root_changes() {
  gen; launch "$(APP_DEMO)"                                               # created in Application Support
  storage --set-prefix-root "$(ROOTD)"
  : > "$FAKE_WINE_LOG"
  launch "$(APP_DEMO)"; assert_rc 0
  assert_file_lacks "$FAKE_WINE_LOG" "wineboot"                           # not recreated
  assert_file_has "$FAKE_WINE_LOG" "env WINEPREFIX=$(prefix_of Demo)"
  assert_missing "$(ROOTD)/Demo"
}

test_a_prefix_from_before_locations_were_recorded_stays_too() {
  gen; launch "$(APP_DEMO)"
  rm -f "$SUPPORT_ROOT/Demo/.prefix-path"                                 # as an app launched by an older version
  storage --set-prefix-root "$(ROOTD)"
  : > "$FAKE_WINE_LOG"
  launch "$(APP_DEMO)"; assert_rc 0
  assert_file_lacks "$FAKE_WINE_LOG" "wineboot"
  assert_file_has "$FAKE_WINE_LOG" "env WINEPREFIX=$(prefix_of Demo)"
}

test_deleting_a_prefix_lets_the_next_launch_use_the_new_root() {
  gen; launch "$(APP_DEMO)"
  storage --set-prefix-root "$(ROOTD)"
  storage --delete-prefix Demo; assert_rc 0
  assert_missing "$SUPPORT_ROOT/Demo/.prefix-path"
  launch "$(APP_DEMO)"; assert_rc 0
  assert_file "$(ROOTD)/Demo/prefix/system.reg"
}

test_an_explicit_prefix_dir_wins_over_the_root() {
  storage --set-prefix-root "$(ROOTD)"
  gen --prefix-dir "$SB/mine/Demo"; launch "$(APP_DEMO)"
  assert_file "$SB/mine/Demo/system.reg"
  assert_missing "$(ROOTD)/Demo"
  assert_file "$SUPPORT_ROOT/Demo/.prefix-pinned"
}

test_the_pinned_marker_follows_the_apps_setting() {
  gen --prefix-dir "$SB/mine/Demo"; launch "$(APP_DEMO)"
  assert_file "$SUPPORT_ROOT/Demo/.prefix-pinned"
  gen; launch "$(APP_DEMO)"                                               # regenerated without a fixed place
  assert_missing "$SUPPORT_ROOT/Demo/.prefix-pinned"
}

test_a_prefix_on_a_disconnected_drive_is_never_replaced_by_a_new_one() {
  # The recorded place is on a volume that is not mounted: the app must say so, not start from scratch elsewhere
  gen
  mkdir -p "$SUPPORT_ROOT/Demo"
  echo "/Volumes/__dmgexe_test_not_mounted__/Bottles/Demo/prefix" > "$SUPPORT_ROOT/Demo/.prefix-path"
  storage --set-prefix-root "$(ROOTD)"
  launch "$(APP_DEMO)"
  assert_rc 1
  assert_file_has "$FAKE_OSA_LOG" "not connected"
  assert_missing "$(ROOTD)/Demo"
  assert_missing "$(prefix_of Demo)"
  assert_file_lacks "$FAKE_WINE_LOG" "wine"
}

test_an_unusable_root_is_reported_at_launch() {
  storage --set-prefix-root "$(ROOTD)"
  gen
  rm -rf "$SB/ext"; : > "$SB/ext"                                         # the drive is gone
  launch "$(APP_DEMO)"
  assert_rc 1
  assert_file_has "$FAKE_OSA_LOG" "Is the external drive connected?"
}

test_installer_flow_follows_the_root() {
  storage --set-prefix-root "$(ROOTD)"
  make_installer "install Program Files/FakeApp/FakeApp.exe"
  inst; assert_rc 0
  assert_file "$(ROOTD)/FakeApp/prefix/drive_c/Program Files/FakeApp/FakeApp.exe"
  assert_missing "$(prefix_of FakeApp)"
  : > "$FAKE_WINE_LOG"
  launch "$(APP_FAKE)"; assert_rc 0
  assert_file_has "$FAKE_WINE_LOG" "cwd=$(ROOTD)/FakeApp/prefix/drive_c/Program Files/FakeApp"
}

test_run_mode_follows_the_root() {
  storage --set-prefix-root "$(ROOTD)"
  dmg -e game.exe -d "$PROG" -n Demo --run; assert_rc 0
  assert_file "$(ROOTD)/Demo/prefix/system.reg"
  assert_missing "$(prefix_of Demo)"
}

test_installed_exe_is_found_in_the_root() {
  storage --set-prefix-root "$(ROOTD)"
  make_installer "install Program Files/FakeApp/FakeApp.exe"
  inst; assert_rc 0
  rm -rf "$OUTD"
  dmg -n FakeApp -o "$OUTD" --installed-exe "Program Files/FakeApp/FakeApp.exe"
  assert_rc 0
}

test_templates_are_cloned_into_the_root() {
  storage --set-prefix-root "$(ROOTD)"
  gen --winetricks "vcrun2008"; launch "$(APP_DEMO)"
  dmg -e game.exe -d "$PROG" -n Other -o "$OUTD" --winetricks "vcrun2008"; : > "$FAKE_TRICKS_LOG"
  launch "$OUTD/Other.app"
  assert_eq "$(cat "$FAKE_TRICKS_LOG")" ""
  assert_file "$(ROOTD)/Other/prefix/drive_c/windows/system32/vcrun2008.dll"
}

test_storage_lists_prefixes_in_the_root() {
  storage --set-prefix-root "$(ROOTD)"
  gen; launch "$(APP_DEMO)"
  storage --list-prefixes
  assert_eq "$(field "$(row prefix Demo)" 3)" "$(ROOTD)/Demo/prefix"
  assert_eq "$(field "$(row prefix Demo)" 6)" 0                           # not pinned
}

test_list_prefixes_marks_fixed_locations() {
  gen --prefix-dir "$SB/mine/Demo"; launch "$(APP_DEMO)"
  storage --list-prefixes
  assert_eq "$(field "$(row prefix Demo)" 6)" 1
}

# --- --move-prefix -----------------------------------------------------------------------------

test_move_prefix_to_the_root() {
  gen --winetricks "vcrun2008"; launch "$(APP_DEMO)"
  echo save > "$(prefix_of Demo)/drive_c/save.dat"
  storage --set-prefix-root "$(ROOTD)"
  storage --move-prefix Demo; assert_rc 0
  assert_contains "$OUT" "moved:"
  assert_missing "$(prefix_of Demo)"
  assert_eq "$(cat "$(ROOTD)/Demo/prefix/drive_c/save.dat")" "save"
  assert_file "$(ROOTD)/Demo/prefix/drive_c/windows/system32/vcrun2008.dll"
  assert_eq "$(cat "$SUPPORT_ROOT/Demo/.prefix-path")" "$(ROOTD)/Demo/prefix"
}

test_a_moved_prefix_is_used_without_being_rebuilt() {
  gen --winetricks "vcrun2008"; launch "$(APP_DEMO)"
  storage --set-prefix-root "$(ROOTD)"; storage --move-prefix Demo
  : > "$FAKE_WINE_LOG"; : > "$FAKE_TRICKS_LOG"
  launch "$(APP_DEMO)"; assert_rc 0
  assert_file_lacks "$FAKE_WINE_LOG" "wineboot"
  assert_eq "$(cat "$FAKE_TRICKS_LOG")" ""
  assert_file_has "$FAKE_WINE_LOG" "env WINEPREFIX=$(ROOTD)/Demo/prefix"
}

test_a_moved_installed_program_still_runs() {
  make_installer "install Program Files/FakeApp/FakeApp.exe"
  inst; assert_rc 0
  storage --set-prefix-root "$(ROOTD)"; storage --move-prefix FakeApp; assert_rc 0
  : > "$FAKE_WINE_LOG"
  launch "$(APP_FAKE)"; assert_rc 0
  assert_file_has "$FAKE_WINE_LOG" "cwd=$(ROOTD)/FakeApp/prefix/drive_c/Program Files/FakeApp"
}

test_move_keeps_symlinks() {
  gen; launch "$(APP_DEMO)"
  storage --set-prefix-root "$(ROOTD)"; storage --move-prefix Demo
  [[ -L "$(ROOTD)/Demo/prefix/dosdevices/c:" ]] || fail "dosdevices/c: must stay a symlink"
}

test_move_back_to_the_default_place() {
  storage --set-prefix-root "$(ROOTD)"
  gen; launch "$(APP_DEMO)"
  storage --set-prefix-root default
  storage --move-prefix Demo; assert_rc 0
  assert_file "$(prefix_of Demo)/system.reg"
  assert_missing "$(ROOTD)/Demo/prefix"
}

test_move_between_volumes_copies_then_removes() {
  gen; launch "$(APP_DEMO)"
  echo save > "$(prefix_of Demo)/drive_c/save.dat"
  storage --set-prefix-root "$(ROOTD)"
  # a stat that says the destination is another volume
  cat > "$SB/fakebin/stat" <<'ST'
#!/bin/bash
if [[ "$1 $2" == "-f %d" ]]; then case "$3" in */ext*) echo 2;; *) echo 1;; esac; exit 0; fi
exec /usr/bin/stat "$@"
ST
  chmod +x "$SB/fakebin/stat"
  storage --move-prefix Demo; assert_rc 0
  assert_eq "$(cat "$(ROOTD)/Demo/prefix/drive_c/save.dat")" "save"
  assert_missing "$(prefix_of Demo)"
}

test_a_failed_copy_between_volumes_changes_nothing() {
  gen; launch "$(APP_DEMO)"
  storage --set-prefix-root "$(ROOTD)"
  cat > "$SB/fakebin/stat" <<'ST'
#!/bin/bash
if [[ "$1 $2" == "-f %d" ]]; then case "$3" in */ext*) echo 2;; *) echo 1;; esac; exit 0; fi
exec /usr/bin/stat "$@"
ST
  printf '#!/bin/bash\nexit 1\n' > "$SB/fakebin/cp"; chmod +x "$SB/fakebin/stat" "$SB/fakebin/cp"
  storage --move-prefix Demo
  assert_rc 1
  assert_contains "$OUT" "nothing was changed"
  assert_file "$(prefix_of Demo)/system.reg"
  assert_missing "$(ROOTD)/Demo/prefix"
}

test_move_refuses_when_already_there() {
  storage --set-prefix-root "$(ROOTD)"
  gen; launch "$(APP_DEMO)"
  storage --move-prefix Demo
  assert_rc 1
  assert_contains "$OUT" "already in"
}

test_move_refuses_a_fixed_location() {
  gen --prefix-dir "$SB/mine/Demo"; launch "$(APP_DEMO)"
  storage --set-prefix-root "$(ROOTD)"
  storage --move-prefix Demo
  assert_rc 1
  assert_contains "$OUT" "fixed location"
  assert_file "$SB/mine/Demo/system.reg"
}

test_move_refuses_while_in_use() {
  gen; launch "$(APP_DEMO)"
  storage --set-prefix-root "$(ROOTD)"
  fake_wine_process "$(prefix_of Demo)"
  storage --move-prefix Demo; local rc=$RC; local out="$OUT"
  kill "$BG" 2>/dev/null; wait "$BG" 2>/dev/null
  assert_eq "$rc" 1
  assert_contains "$out" "in use"
  assert_file "$(prefix_of Demo)/system.reg"
}

test_move_refuses_an_existing_destination() {
  gen; launch "$(APP_DEMO)"
  storage --set-prefix-root "$(ROOTD)"
  mkdir -p "$(ROOTD)/Demo/prefix"
  storage --move-prefix Demo
  assert_rc 1
  assert_contains "$OUT" "already exists"
  assert_file "$(prefix_of Demo)/system.reg"
}

test_move_rejects_unknown_or_odd_names() {
  storage --set-prefix-root "$(ROOTD)"
  storage --move-prefix Nobody;  assert_rc 1
  storage --move-prefix "../x";  assert_rc 1
  storage --move-prefix "a/b";   assert_rc 1
}

test_move_reports_a_disconnected_source() {
  gen --prefix-dir "$SB/ext2/Demo"; launch "$(APP_DEMO)"
  rm -f "$SUPPORT_ROOT/Demo/.prefix-pinned"; rm -rf "$SB/ext2"
  storage --set-prefix-root "$(ROOTD)"
  storage --move-prefix Demo
  assert_rc 1
  assert_contains "$OUT" "Is its drive connected?"
}

test_help_documents_the_root() {
  run /bin/bash "$SCRIPT" --help
  assert_contains "$OUT" "--set-prefix-root"
  assert_contains "$OUT" "--get-prefix-root"
  assert_contains "$OUT" "--move-prefix"
}
