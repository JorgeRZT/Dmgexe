# What a generated app does when launched (against the fake Wine).

test_first_launch_creates_prefix_and_runs_program() {
  gen; assert_rc 0
  launch "$(APP_DEMO)"; assert_rc 0
  local px; px="$(prefix_of Demo)"
  assert_file "$px/system.reg"
  assert_file_has "$FAKE_WINE_LOG" "wine wineboot --init"
  assert_file_has "$FAKE_WINE_LOG" "wine game.exe"
  # the program starts from its own folder and the prefix is the app's own
  assert_file_has "$FAKE_WINE_LOG" "cwd=$(APP_DEMO)/Contents/Resources/program"
  assert_file_has "$FAKE_WINE_LOG" "env WINEPREFIX=$px"
  assert_file "$SUPPORT_ROOT/Demo/launcher.log"
  assert_file_has "$SUPPORT_ROOT/Demo/launcher.log" "launching game.exe"
  assert_file_has "$FAKE_OSA_LOG" "Preparing the Windows environment"
}

test_second_launch_reuses_prefix() {
  gen; assert_rc 0
  launch "$(APP_DEMO)"; launch "$(APP_DEMO)"
  assert_count "$FAKE_WINE_LOG" "wine wineboot --init" 1
  assert_count "$FAKE_WINE_LOG" "wine game.exe" 2
}

test_launch_from_subfolder_exe() {
  dmg -e bin/tool.exe -d "$PROG" -n Demo -o "$OUTD"; assert_rc 0
  launch "$(APP_DEMO)"
  assert_file_has "$FAKE_WINE_LOG" "wine tool.exe"
  assert_file_has "$FAKE_WINE_LOG" "cwd=$(APP_DEMO)/Contents/Resources/program/bin"
}

test_link_mode_runs_from_original_folder() {
  gen --link; assert_rc 0
  launch "$(APP_DEMO)"
  assert_file_has "$FAKE_WINE_LOG" "cwd=$PROG"
}

test_embedded_runtime_is_used() {
  gen --embed-wine; assert_rc 0
  mv "$WINE" "$SB/wine-moved"      # the remembered path no longer works; the embedded copy must
  launch "$(APP_DEMO)"; assert_rc 0
  assert_file_has "$FAKE_WINE_LOG" "wine game.exe"
}

test_program_args_are_passed_intact() {
  gen --arg "--windowed" --arg "two words" --arg "it's"; assert_rc 0
  launch "$(APP_DEMO)"
  assert_file_has "$FAKE_WINE_LOG" "  arg=--windowed"
  assert_file_has "$FAKE_WINE_LOG" "  arg=two words"
  assert_file_has "$FAKE_WINE_LOG" "  arg=it's"
}

test_extra_env_is_exported() {
  gen --env FOO=bar; assert_rc 0
  launch "$(APP_DEMO)"
  assert_file_has "$FAKE_WINE_LOG" "env FOO=bar"
}

test_sync_flags_default_on() {
  gen; launch "$(APP_DEMO)"
  assert_file_has "$FAKE_WINE_LOG" "env WINEMSYNC=1"
  assert_file_has "$FAKE_WINE_LOG" "env WINEESYNC=1"
}

test_sync_flags_can_be_disabled() {
  gen --no-msync --no-esync; launch "$(APP_DEMO)"
  assert_file_lacks "$FAKE_WINE_LOG" "WINEMSYNC"
  assert_file_lacks "$FAKE_WINE_LOG" "WINEESYNC"
}

test_win32_sets_arch() {
  gen --win32; launch "$(APP_DEMO)"
  assert_file_has "$FAKE_WINE_LOG" "env WINEARCH=win32"
}

test_retina_off_by_default() {
  gen; launch "$(APP_DEMO)"
  assert_file_has "$FAKE_WINE_LOG" 'reg add HKCU\Software\Wine\Mac Driver /v RetinaMode /t REG_SZ /d n /f'
  assert_file "$SUPPORT_ROOT/Demo/.retina-0"
}

test_retina_on() {
  gen --retina; launch "$(APP_DEMO)"
  assert_file_has "$FAKE_WINE_LOG" 'reg add HKCU\Software\Wine\Mac Driver /v RetinaMode /t REG_SZ /d y /f'
  assert_file "$SUPPORT_ROOT/Demo/.retina-1"
  assert_missing "$SUPPORT_ROOT/Demo/.retina-0"
}

test_retina_registry_written_only_once() {
  gen; launch "$(APP_DEMO)"; launch "$(APP_DEMO)"
  assert_count "$FAKE_WINE_LOG" "wine reg add" 1
}

test_winemenubuilder_disabled() {
  gen; launch "$(APP_DEMO)"
  assert_file_has "$FAKE_WINE_LOG" "env WINEDLLOVERRIDES=winemenubuilder.exe=d"
}

test_d3dmetal_enables_metalfx() {
  gen --gfx d3dmetal; launch "$(APP_DEMO)"
  assert_file_has "$FAKE_WINE_LOG" "env D3DM_ENABLE_METALFX=1"
}

test_auto_gfx_sets_no_backend_env() {
  gen; launch "$(APP_DEMO)"
  assert_file_lacks "$FAKE_WINE_LOG" "D3DM_ENABLE_METALFX"
  assert_file_lacks "$FAKE_WINE_LOG" "GALLIUM_DRIVER"
}

test_leaving_software_opengl_restores_dlls() {
  gen; assert_rc 0
  launch "$(APP_DEMO)"            # creates the prefix
  local s32="$(prefix_of Demo)/drive_c/windows/system32"
  echo mesa > "$s32/opengl32.dll"; echo mesa > "$s32/libgallium_wgl.dll"; echo orig > "$s32/opengl32.dll.orig"
  touch "$SUPPORT_ROOT/Demo/.opengl-done"
  launch "$(APP_DEMO)"
  assert_eq "$(cat "$s32/opengl32.dll")" "orig"
  assert_missing "$s32/libgallium_wgl.dll"
  assert_missing "$s32/opengl32.dll.orig"
  assert_missing "$SUPPORT_ROOT/Demo/.opengl-done"
}

test_winetricks_runs_once() {
  gen --winetricks "vcrun2022 d3dx9"; assert_rc 0
  launch "$(APP_DEMO)"; launch "$(APP_DEMO)"
  assert_count "$FAKE_TRICKS_LOG" "winetricks -q vcrun2022 d3dx9" 1
  assert_file "$SUPPORT_ROOT/Demo/.winetricks-done"
}

test_no_winetricks_when_not_requested() {
  gen; launch "$(APP_DEMO)"
  assert_eq "$(cat "$FAKE_TRICKS_LOG")" ""
}

test_missing_program_shows_alert() {
  gen --link; assert_rc 0
  rm -rf "$PROG"
  launch "$(APP_DEMO)"
  assert_rc 1
  assert_file_has "$FAKE_OSA_LOG" "Cannot find the program at"
  assert_file_lacks "$FAKE_WINE_LOG" "wine game.exe"
}

test_prefix_failure_shows_alert() {
  gen; assert_rc 0
  FAKE_WINEBOOT_FAIL=1 launch "$(APP_DEMO)"
  assert_rc 1
  assert_file_has "$FAKE_OSA_LOG" "Prefix creation failed"
  assert_file_lacks "$FAKE_WINE_LOG" "wine game.exe"
}

test_no_runtime_shows_alert() {
  gen; assert_rc 0
  mv "$WINE" "$SB/wine-moved"
  # only valid when the machine has no other runtime in the usual places
  ls /Applications/Wine*.app /opt/homebrew/bin/wine* /usr/local/bin/wine* >/dev/null 2>&1 && skip "this machine has a Wine installed"
  launch "$(APP_DEMO)"
  assert_rc 1
  assert_file_has "$FAKE_OSA_LOG" "No runtime was found"
}

test_program_exit_code_is_propagated() {
  echo "exit 5" > "$PROG/game.exe"
  gen; launch "$(APP_DEMO)"
  assert_rc 5
}

test_foreground_mode_streams_output() {
  gen
  DMGEXE_FOREGROUND=1 launch "$(APP_DEMO)"
  assert_contains "$OUT" "launching game.exe"
  assert_file_has "$SUPPORT_ROOT/Demo/launcher.log" "launching game.exe"
}

test_two_apps_have_separate_prefixes() {
  gen; dmg -e game.exe -d "$PROG" -n Other -o "$OUTD"
  launch "$(APP_DEMO)"; launch "$OUTD/Other.app"
  assert_file "$(prefix_of Demo)/system.reg"
  assert_file "$(prefix_of Other)/system.reg"
  assert_count "$FAKE_WINE_LOG" "wine wineboot --init" 2
}

# --- order of the first-launch steps ---------------------------------------------------------

line_of() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }

test_winetricks_runs_before_the_windows_version_is_set() {
  # dotnet verbs change the version themselves: the chosen one must be applied after them
  gen --winetricks "dotnet48" --winver 7; assert_rc 0
  launch "$(APP_DEMO)"
  local t v; t="$(line_of "$FAKE_WINE_LOG" "winetricks -q dotnet48")"; v="$(line_of "$FAKE_WINE_LOG" "/v Version")"
  [[ -n "$t" && -n "$v" && $t -lt $v ]] || fail "winetricks (line $t) must come before the version (line $v)"
}

test_winetricks_runs_before_the_program() {
  gen --winetricks "vcrun2008"; launch "$(APP_DEMO)"
  local t r; t="$(line_of "$FAKE_WINE_LOG" "winetricks -q vcrun2008")"; r="$(line_of "$FAKE_WINE_LOG" "wine game.exe")"
  [[ -n "$t" && -n "$r" && $t -lt $r ]] || fail "winetricks must finish before the program starts"
}

test_launcher_says_that_winetricks_can_take_long() {
  dmg -e game.exe -d "$PROG" -n Demo --run --winetricks "dotnet48"
  assert_contains "$OUT" "this can take many minutes"
  assert_file_has "$FAKE_OSA_LOG" "this can take a while"
}

test_moltenvk_log_is_quiet_by_default() {
  gen; launch "$(APP_DEMO)"
  assert_file_has "$FAKE_WINE_LOG" "env MVK_CONFIG_LOG_LEVEL=1"
}

test_moltenvk_log_level_can_be_overridden() {
  gen --env MVK_CONFIG_LOG_LEVEL=3; launch "$(APP_DEMO)"
  assert_file_has "$FAKE_WINE_LOG" "env MVK_CONFIG_LOG_LEVEL=3"
}
