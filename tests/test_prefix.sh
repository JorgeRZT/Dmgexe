# --prefix-dir: keep the Windows prefix (and so an installed program) somewhere else, e.g. an external volume.

EXT() { echo "$SB/ext/Games/MyApp"; }     # stands in for /Volumes/Disk/...

test_prefix_dir_moves_the_prefix_of_a_normal_app() {
  gen --prefix-dir "$(EXT)"; assert_rc 0
  assert_dir "$(EXT)"
  launch "$(APP_DEMO)"; assert_rc 0
  assert_file "$(EXT)/system.reg"
  assert_file_has "$FAKE_WINE_LOG" "env WINEPREFIX=$(EXT)"
  assert_missing "$(prefix_of Demo)"                       # nothing on the internal disk...
  assert_file "$SUPPORT_ROOT/Demo/launcher.log"            # ...except the small log
}

test_prefix_dir_is_reused_on_the_second_launch() {
  gen --prefix-dir "$(EXT)"
  launch "$(APP_DEMO)"; launch "$(APP_DEMO)"
  assert_count "$FAKE_WINE_LOG" "wine wineboot --init" 1
}

test_default_prefix_is_unchanged_without_the_option() {
  gen; launch "$(APP_DEMO)"
  assert_eq "$(launcher_var "$(APP_DEMO)" PREFIX_OVERRIDE)" ""
  assert_file "$(prefix_of Demo)/system.reg"
}

test_relative_prefix_dir_becomes_absolute() {
  mkdir -p "$SB/cwd"
  ( cd "$SB/cwd" && dmg -e "$PROG/game.exe" -n Demo -o "$OUTD" --prefix-dir rel/prefix; echo "$RC" > "$SB/rc" )
  assert_eq "$(cat "$SB/rc")" 0
  assert_eq "$(launcher_var "$(APP_DEMO)" PREFIX_OVERRIDE)" "$SB/cwd/rel/prefix"
}

test_unavailable_volume_is_reported_when_generating() {
  : > "$SB/notadir"
  gen --prefix-dir "$SB/notadir/prefix"
  assert_rc 1
  assert_contains "$OUT" "cannot create the prefix folder"
  assert_missing "$(APP_DEMO)"
}

test_unavailable_volume_is_reported_when_launching() {
  gen --prefix-dir "$(EXT)"; assert_rc 0
  rm -rf "$SB/ext"; : > "$SB/ext"                          # the drive is gone
  launch "$(APP_DEMO)"
  assert_rc 1
  assert_file_has "$FAKE_OSA_LOG" "Is the external drive connected?"
  assert_file_lacks "$FAKE_WINE_LOG" "wine game.exe"
}

test_run_mode_uses_the_prefix_dir() {
  dmg -e game.exe -d "$PROG" -n Demo --run --prefix-dir "$(EXT)"
  assert_rc 0
  assert_file "$(EXT)/system.reg"
  assert_missing "$(prefix_of Demo)"
}

test_installer_installs_into_the_chosen_location() {
  make_installer "install Program Files/FakeApp/FakeApp.exe"
  inst --prefix-dir "$(EXT)"; assert_rc 0
  assert_file "$(EXT)/drive_c/Program Files/FakeApp/FakeApp.exe"
  assert_missing "$(prefix_of FakeApp)"
  assert_file_has "$FAKE_WINE_LOG" "env WINEPREFIX=$(EXT)"
  assert_eq "$(launcher_var "$(APP_FAKE)" PREFIX_OVERRIDE)" "$(EXT)"
  assert_file_has "$FAKE_WINE_LOG" "wineserver -w prefix=$(EXT)"
}

test_installed_app_launches_from_the_chosen_location() {
  make_installer "install Program Files/FakeApp/FakeApp.exe"
  inst --prefix-dir "$(EXT)"; assert_rc 0
  : > "$FAKE_WINE_LOG"
  launch "$(APP_FAKE)"; assert_rc 0
  assert_file_has "$FAKE_WINE_LOG" "cwd=$(EXT)/drive_c/Program Files/FakeApp"
  assert_file_lacks "$FAKE_WINE_LOG" "setup.exe"
}

test_ambiguous_install_then_choice_keeps_the_location() {
  make_installer "install Program Files/Suite/Alpha.exe" "install Program Files/Suite/Beta.exe"
  inst --prefix-dir "$(EXT)"; assert_rc 3
  dmg -n FakeApp -o "$OUTD" --prefix-dir "$(EXT)" --installed-exe "C:\\Program Files\\Suite\\Beta.exe"
  assert_rc 0
  assert_eq "$(launcher_var "$(APP_FAKE)" PREFIX_OVERRIDE)" "$(EXT)"
  assert_count "$FAKE_WINE_LOG" "wine setup.exe" 1
}

test_installed_exe_is_looked_up_in_the_chosen_location() {
  dmg -n FakeApp -o "$OUTD" --installed-exe "Program Files/FakeApp/FakeApp.exe"      # not in the default prefix
  assert_rc 1
  mkdir -p "$(EXT)/drive_c/Program Files/FakeApp"; echo x > "$(EXT)/drive_c/Program Files/FakeApp/FakeApp.exe"
  dmg -n FakeApp -o "$OUTD" --prefix-dir "$(EXT)" --installed-exe "Program Files/FakeApp/FakeApp.exe"
  assert_rc 0
  dmg -n FakeApp -o "$OUTD" --prefix-dir "$(EXT)" --installed-exe "$(EXT)/drive_c/Program Files/FakeApp/FakeApp.exe"
  assert_rc 0                                                                          # full path form
}

test_profile_keeps_the_prefix_dir() {
  run /bin/bash "$SCRIPT" -e game.exe -d "$PROG" -n Demo -w "$WINE" --no-d3dcompiler --prefix-dir "$(EXT)" --save-profile "$SB/p.profile"
  assert_rc 0
  assert_file_has "$SB/p.profile" "PREFIX_OVERRIDE="
  run /bin/bash "$SCRIPT" --profile "$SB/p.profile" -o "$OUTD"
  assert_rc 0
  assert_eq "$(launcher_var "$(APP_DEMO)" PREFIX_OVERRIDE)" "$(EXT)"
}

test_help_documents_prefix_dir() {
  run /bin/bash "$SCRIPT" --help
  assert_contains "$OUT" "--prefix-dir"
}
