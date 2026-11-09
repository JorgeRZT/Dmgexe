# Installer mode: --install / --installed-exe.

# make_installer [DIR] LINE...: a fake setup.exe at DIR/setup.exe (default $SB/inst) that does LINE...
make_installer() {
  local d="$SB/inst"
  if [[ -d "$1" || "$1" == "$SB"/* ]]; then d="$1"; shift; fi
  mkdir -p "$d"; : > "$d/setup.exe"
  local l; for l in "$@"; do echo "$l" >> "$d/setup.exe"; done
}
# the usual installer: a main program, plus the things that must be ignored
standard_installer() {
  make_installer \
    "install Program Files/FakeApp/FakeApp.exe" \
    "install Program Files/FakeApp/unins000.exe" \
    "install Program Files/FakeApp/crashpad_handler.exe" \
    "install Program Files/Common Files/shared.exe" \
    "install users/me/AppData/Local/Temp/extract.exe"
}
# inst ARGS...: install the standard installer as FakeApp
inst() { dmg --install -e "$SB/inst/setup.exe" -n FakeApp -o "$OUTD" "$@"; }
APP_FAKE() { echo "$OUTD/FakeApp.app"; }

test_install_runs_installer_in_the_apps_prefix() {
  standard_installer
  inst; assert_rc 0
  # the installer ran once, from its own folder, in the prefix named after the app
  assert_count "$FAKE_WINE_LOG" "wine setup.exe" 1
  assert_file_has "$FAKE_WINE_LOG" "cwd=$SB/inst"
  assert_file_has "$FAKE_WINE_LOG" "env WINEPREFIX=$(prefix_of FakeApp)"
  assert_file "$(prefix_of FakeApp)/drive_c/Program Files/FakeApp/FakeApp.exe"
}

test_install_generates_app_for_the_installed_program() {
  standard_installer
  inst; assert_rc 0
  assert_contains "$OUT" "installed-exe: drive_c/Program Files/FakeApp/FakeApp.exe"
  local app; app="$(APP_FAKE)"
  assert_exec "$app/Contents/MacOS/launcher"
  assert_missing "$app/Contents/Resources/program"      # nothing is copied
  assert_eq "$(launcher_var "$app" PROGRAM_PREFIX_DIR)" "drive_c/Program Files/FakeApp"
  assert_eq "$(launcher_var "$app" EXE_REL)" "FakeApp.exe"
  assert_eq "$(launcher_var "$app" PROGRAM_REF)" ""
  /bin/bash -n "$(launcher_of "$app")" || fail "the launcher has a syntax error"
}

test_installed_app_runs_the_program_from_the_prefix() {
  standard_installer
  inst; assert_rc 0
  : > "$FAKE_WINE_LOG"
  launch "$(APP_FAKE)"; assert_rc 0
  assert_file_has "$FAKE_WINE_LOG" "wine FakeApp.exe"
  assert_file_has "$FAKE_WINE_LOG" "cwd=$(prefix_of FakeApp)/drive_c/Program Files/FakeApp"
  assert_file_lacks "$FAKE_WINE_LOG" "setup.exe"          # the installer is not run again
  assert_file_lacks "$FAKE_WINE_LOG" "wineboot"           # and the prefix is reused
}

test_installer_junk_and_wine_defaults_are_ignored() {
  standard_installer
  inst; assert_rc 0
  assert_not_contains "$OUT" "iexplore"
  assert_not_contains "$OUT" "wordpad"
  assert_not_contains "$OUT" "unins000"
  assert_not_contains "$OUT" "crashpad"
  assert_not_contains "$OUT" "shared.exe"
  assert_not_contains "$OUT" "extract.exe"
}

test_installer_args_are_not_passed_to_the_installer_but_to_the_program() {
  standard_installer
  inst --arg "--windowed"; assert_rc 0
  assert_file_lacks "$FAKE_WINE_LOG" "arg=--windowed"     # nothing ran the program yet
  assert_file_has "$(launcher_of "$(APP_FAKE)")" "PROGRAM_ARGS=(--windowed )"
}

test_installer_gets_the_runtime_settings() {
  standard_installer
  inst --env FOO=bar --no-msync --winetricks "vcrun2022"; assert_rc 0
  # the installer sees the same environment as the program will, and winetricks ran before it
  assert_file_has "$FAKE_WINE_LOG" "env FOO=bar"
  assert_file_lacks "$FAKE_WINE_LOG" "WINEMSYNC"
  assert_count "$FAKE_TRICKS_LOG" "winetricks -q vcrun2022" 1
  assert_eq "$(launcher_var "$(APP_FAKE)" WINETRICKS)" "vcrun2022"
}

test_install_waits_for_every_process_of_the_installer() {
  standard_installer
  inst; assert_rc 0
  assert_file_has "$FAKE_WINE_LOG" "wineserver -w"
}

test_install_with_run_runs_the_installed_program() {
  standard_installer
  inst --run; assert_rc 0
  assert_missing "$(APP_FAKE)"                            # no app is kept
  assert_file_has "$FAKE_WINE_LOG" "wine FakeApp.exe"
  assert_file_has "$FAKE_WINE_LOG" "cwd=$(prefix_of FakeApp)/drive_c/Program Files/FakeApp"
}

test_install_with_run_propagates_the_programs_exit_code() {
  make_installer "install Program Files/FakeApp/FakeApp.exe"
  inst --run; assert_rc 0
  echo "exit 9" > "$(prefix_of FakeApp)/drive_c/Program Files/FakeApp/FakeApp.exe"
  dmg -n FakeApp --installed-exe "Program Files/FakeApp/FakeApp.exe" --run
  assert_rc 9
}

test_installer_nonzero_exit_still_uses_what_it_installed() {
  make_installer "install Program Files/FakeApp/FakeApp.exe" "exit 3010"
  inst; assert_rc 0
  assert_contains "$OUT" "the installer ended with code"
  assert_dir "$(APP_FAKE)"
}

test_installer_that_installs_nothing_fails() {
  make_installer "exit 1"
  inst
  assert_rc 1
  assert_contains "$OUT" "did not leave any new program"
  assert_missing "$(APP_FAKE)"
}

test_installer_that_only_leaves_junk_fails() {
  make_installer "install Program Files/FakeApp/unins000.exe" "install users/me/AppData/Local/Temp/x.exe"
  inst
  assert_rc 1
  assert_contains "$OUT" "did not leave any new program"
}

# --- several candidates --------------------------------------------------------------------

two_unrelated_programs() {
  make_installer "install Program Files/Suite/Alpha.exe" "install Program Files/Suite/Beta.exe"
}

test_ambiguous_install_lists_candidates_and_exits_3() {
  two_unrelated_programs
  inst
  assert_rc 3
  assert_contains "$OUT" "candidate: drive_c/Program Files/Suite/Alpha.exe"
  assert_contains "$OUT" "candidate: drive_c/Program Files/Suite/Beta.exe"
  assert_missing "$(APP_FAKE)"
  # what the installer did is kept
  assert_file "$(prefix_of FakeApp)/drive_c/Program Files/Suite/Alpha.exe"
}

test_choosing_afterwards_does_not_rerun_the_installer() {
  two_unrelated_programs
  inst; assert_rc 3
  dmg -n FakeApp -o "$OUTD" --installed-exe "drive_c/Program Files/Suite/Beta.exe"
  assert_rc 0
  assert_count "$FAKE_WINE_LOG" "wine setup.exe" 1
  assert_eq "$(launcher_var "$(APP_FAKE)" EXE_REL)" "Beta.exe"
  assert_eq "$(launcher_var "$(APP_FAKE)" PROGRAM_PREFIX_DIR)" "drive_c/Program Files/Suite"
}

test_install_with_explicit_exe_skips_detection() {
  two_unrelated_programs
  inst --installed-exe "C:\\Program Files\\Suite\\Alpha.exe"
  assert_rc 0
  assert_eq "$(launcher_var "$(APP_FAKE)" EXE_REL)" "Alpha.exe"
  assert_not_contains "$OUT" "candidate:"
}

test_install_with_explicit_exe_that_does_not_exist_fails() {
  standard_installer
  inst --installed-exe "C:\\Nope\\none.exe"
  assert_rc 1
  assert_contains "$OUT" "not found in the prefix"
}

test_clear_winner_is_chosen_without_asking() {
  make_installer "install Program Files/FakeApp/FakeApp.exe" "install Program Files/FakeApp/Config Tool.exe"
  inst; assert_rc 0
  assert_eq "$(launcher_var "$(APP_FAKE)" EXE_REL)" "FakeApp.exe"
  assert_contains "$OUT" "also found: drive_c/Program Files/FakeApp/Config Tool.exe"
}

test_program_named_like_the_app_wins_over_others() {
  make_installer "install Program Files/Studio/Editor.exe" "install Program Files/Studio/FakeApp.exe"
  inst; assert_rc 0
  assert_eq "$(launcher_var "$(APP_FAKE)" EXE_REL)" "FakeApp.exe"
}

test_programs_in_program_files_beat_other_places() {
  make_installer "install Program Files/Tool/Tool.exe" "install Games/Other/Other.exe"
  inst; assert_rc 0
  assert_eq "$(launcher_var "$(APP_FAKE)" EXE_REL)" "Tool.exe"
}

test_per_user_installs_are_found() {
  make_installer "install users/me/AppData/Local/Programs/Chatty/Chatty.exe" "install users/me/AppData/Local/Temp/tmp123.exe"
  inst; assert_rc 0
  assert_eq "$(launcher_var "$(APP_FAKE)" PROGRAM_PREFIX_DIR)" "drive_c/users/me/AppData/Local/Programs/Chatty"
}

# --- a second installation in the same prefix ----------------------------------------------

test_only_what_the_new_installer_adds_counts() {
  standard_installer
  inst; assert_rc 0                                        # FakeApp is now in the prefix
  make_installer "install Program Files/Second/Second.exe"
  dmg --install -e "$SB/inst/setup.exe" -n FakeApp -o "$OUTD/second"
  assert_rc 0
  assert_eq "$(launcher_var "$OUTD/second/FakeApp.app" EXE_REL)" "Second.exe"
  assert_not_contains "$OUT" "candidate:"
}

# --- --installed-exe forms and errors --------------------------------------------------------

prepared_prefix() {
  standard_installer
  inst; assert_rc 0
  rm -rf "$OUTD"
}

test_installed_exe_accepts_the_usual_path_forms() {
  prepared_prefix
  local px; px="$(prefix_of FakeApp)"
  local f
  for f in 'C:\Program Files\FakeApp\FakeApp.exe' 'c:/Program Files/FakeApp/FakeApp.exe' \
           'drive_c/Program Files/FakeApp/FakeApp.exe' 'Program Files/FakeApp/FakeApp.exe' \
           "$px/drive_c/Program Files/FakeApp/FakeApp.exe"; do
    dmg -n FakeApp -o "$OUTD" --installed-exe "$f"
    [[ $RC -eq 0 ]] || fail "form [$f] rejected: $OUT"
    assert_eq "$(launcher_var "$(APP_FAKE)" PROGRAM_PREFIX_DIR)" "drive_c/Program Files/FakeApp"
  done
}

test_installed_exe_needs_a_name() {
  dmg --installed-exe "C:\\Program Files\\x.exe" -o "$OUTD"
  assert_rc 1
  assert_contains "$OUT" "--installed-exe needs --name"
}

test_installed_exe_must_exist() {
  prepared_prefix
  dmg -n FakeApp -o "$OUTD" --installed-exe "C:\\Program Files\\FakeApp\\missing.exe"
  assert_rc 1
  assert_contains "$OUT" "not found in the prefix of 'FakeApp'"
}

test_installed_exe_unknown_prefix_fails() {
  dmg -n NoSuchApp -o "$OUTD" --installed-exe "C:\\Program Files\\FakeApp\\FakeApp.exe"
  assert_rc 1
  assert_contains "$OUT" "not found in the prefix"
}

test_installed_exe_rejects_other_drives() {
  prepared_prefix
  dmg -n FakeApp -o "$OUTD" --installed-exe 'D:\Games\g.exe'
  assert_rc 1
  assert_contains "$OUT" "only drive C:"
}

test_installed_exe_rejects_escaping_the_prefix() {
  prepared_prefix
  echo x > "$SB/outside.exe"
  dmg -n FakeApp -o "$OUTD" --installed-exe 'C:\Program Files\..\..\..\..\outside.exe'
  assert_rc 1
  assert_contains "$OUT" "must not contain '..'"
  dmg -n FakeApp -o "$OUTD" --installed-exe "$SB/outside.exe"
  assert_rc 1
  assert_contains "$OUT" "outside the prefix"
}

test_install_requires_the_installer() {
  run /bin/bash "$SCRIPT" -w "$WINE" --install
  assert_rc 1
  assert_contains "$OUT" "missing --exe"
}

test_installer_must_exist() {
  inst
  assert_rc 1
  assert_contains "$OUT" "exe not found"
}

# --- naming ----------------------------------------------------------------------------------

test_generic_installer_name_falls_back_to_its_folder() {
  make_installer "$SB/Cool Game" "install Program Files/Cool Game/CoolGame.exe"
  dmg --install -e "$SB/Cool Game/setup.exe" -o "$OUTD"
  assert_rc 0
  assert_dir "$OUTD/Cool Game.app"
  assert_dir "$(prefix_of "Cool Game")/drive_c/Program Files/Cool Game"
}

test_explicit_name_wins_over_the_installer_name() {
  standard_installer
  inst; assert_rc 0
  assert_dir "$(APP_FAKE)"
}

# --- the launcher of an installed program ----------------------------------------------------

test_missing_installed_program_explains_what_happened() {
  standard_installer
  inst; assert_rc 0
  rm -rf "$(prefix_of FakeApp)/drive_c/Program Files/FakeApp"
  launch "$(APP_FAKE)"
  assert_rc 1
  assert_file_has "$FAKE_OSA_LOG" "Cannot find the program at"
  assert_file_has "$FAKE_OSA_LOG" "Windows prefix"
}

test_installed_app_survives_a_prefix_without_the_program_being_rebuilt() {
  standard_installer
  inst; assert_rc 0
  launch "$(APP_FAKE)"; launch "$(APP_FAKE)"
  assert_count "$FAKE_WINE_LOG" "wine FakeApp.exe" 2
}

test_installed_app_uses_its_own_runtime_settings() {
  standard_installer
  inst --retina --gfx d3dmetal; assert_rc 0
  launch "$(APP_FAKE)"
  assert_file_has "$FAKE_WINE_LOG" "env D3DM_ENABLE_METALFX=1"
  assert_file_has "$FAKE_WINE_LOG" 'RetinaMode /t REG_SZ /d y /f'
}

test_installed_embed_wine_still_embeds() {
  standard_installer
  inst --embed-wine; assert_rc 0
  assert_exec "$(APP_FAKE)/Contents/Resources/runtime/bin/wine64"
  assert_missing "$(APP_FAKE)/Contents/Resources/program"
}

test_link_flag_is_harmless_with_an_installed_program() {
  standard_installer
  inst --link; assert_rc 0
  assert_eq "$(launcher_var "$(APP_FAKE)" PROGRAM_REF)" ""
  assert_eq "$(launcher_var "$(APP_FAKE)" PROGRAM_PREFIX_DIR)" "drive_c/Program Files/FakeApp"
}

# --- profiles --------------------------------------------------------------------------------

test_profile_keeps_the_installed_exe() {
  run /bin/bash "$SCRIPT" -n FakeApp -w "$WINE" --no-d3dcompiler --installed-exe "C:\\Program Files\\FakeApp\\FakeApp.exe" \
      --save-profile "$SB/i.profile"
  assert_rc 0
  assert_file_has "$SB/i.profile" "INSTALLED_EXE="
  assert_file_has "$SB/i.profile" "INSTALL=0"
}

test_profile_can_describe_an_installation() {
  standard_installer
  run /bin/bash "$SCRIPT" -e "$SB/inst/setup.exe" -n FakeApp -w "$WINE" --no-d3dcompiler --install --save-profile "$SB/i.profile"
  assert_rc 0
  assert_file_has "$SB/i.profile" "INSTALL=1"
  run /bin/bash "$SCRIPT" --profile "$SB/i.profile" -o "$OUTD"       # runs the installer, then builds the app
  assert_rc 0
  assert_dir "$(APP_FAKE)"
  assert_count "$FAKE_WINE_LOG" "wine setup.exe" 1              # the stages do not loop
}

test_profile_of_an_installed_program_builds_the_app() {
  prepared_prefix
  run /bin/bash "$SCRIPT" -n FakeApp -w "$WINE" --no-d3dcompiler --installed-exe "Program Files/FakeApp/FakeApp.exe" \
      --save-profile "$SB/i.profile"
  run /bin/bash "$SCRIPT" --profile "$SB/i.profile" -o "$OUTD"
  assert_rc 0
  assert_eq "$(launcher_var "$(APP_FAKE)" EXE_REL)" "FakeApp.exe"
}
