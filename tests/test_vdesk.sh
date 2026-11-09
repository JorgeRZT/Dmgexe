# --virtual-desktop: run the program inside a Wine virtual desktop (a window) instead of letting it take over the
# screen. And the warning for options typed after --arg, which go to the PROGRAM, not to dmgexe.

test_virtual_desktop_runs_the_program_in_an_explorer_desktop() {
  gen --virtual-desktop 1920x1080; assert_rc 0
  launch "$(APP_DEMO)"; assert_rc 0
  assert_file_has "$FAKE_WINE_LOG" "wine explorer /desktop=Demo,1920x1080 Z:"
  assert_file_has "$FAKE_WINE_LOG" "  arg=/desktop=Demo,1920x1080"
}

# Regression: with a bare "game.exe" explorer opened an empty desktop and never started the program (Anno 1404).
test_the_program_is_given_to_explorer_as_a_full_windows_path() {
  gen --virtual-desktop 1280x720; launch "$(APP_DEMO)"
  local a; a="$(grep '^  arg=Z:' "$FAKE_WINE_LOG" | head -1)"
  [[ -n "$a" ]] || fail "no full Windows path was passed: $(cat "$FAKE_WINE_LOG")"
  case "$a" in *'\game.exe') ;; *) fail "path does not end in \\game.exe: $a" ;; esac
  case "$a" in */*) fail "path still has slashes: $a" ;; esac
}

test_the_program_still_starts_from_its_own_folder() {
  gen --virtual-desktop 1280x720; launch "$(APP_DEMO)"
  assert_file_has "$FAKE_WINE_LOG" "cwd=$(APP_DEMO)/Contents/Resources/program"
}

test_program_arguments_follow_the_executable() {
  gen --virtual-desktop 1280x720 --arg "--windowed" --arg "two words"; launch "$(APP_DEMO)"
  local l; l="$(grep -n "^wine explorer" "$FAKE_WINE_LOG" | head -1 | cut -d: -f1)"
  [[ -n "$l" ]] || fail "explorer was not started"
  assert_eq "$(sed -n "$((l+4)),$((l+6))p" "$FAKE_WINE_LOG" | grep '  arg=' | sed 's/arg=Z:.*\\/arg=/' | tr '\n' '|')" "  arg=game.exe|  arg=--windowed|  arg=two words|"
}

test_no_virtual_desktop_by_default() {
  gen; launch "$(APP_DEMO)"
  assert_file_lacks "$FAKE_WINE_LOG" "explorer"
  assert_file_has "$FAKE_WINE_LOG" "wine game.exe"
  assert_eq "$(launcher_var "$(APP_DEMO)" VDESK)" ""
}

test_virtual_desktop_name_is_the_apps_slug_without_spaces_or_commas() {
  dmg -e game.exe -d "$PROG" -n "My Game, 2" -o "$OUTD" --virtual-desktop 1024x768
  assert_rc 0
  launch "$OUTD/My Game, 2.app"
  assert_file_has "$FAKE_WINE_LOG" "wine explorer /desktop=My-Game-2,1024x768 Z:"
}

test_virtual_desktop_accepts_sensible_sizes_only() {
  local v
  for v in 800x600 1920x1080 2560x1440 3840x2160; do
    gen --virtual-desktop "$v"; [[ $RC -eq 0 ]] || fail "[$v] rejected: $OUT"
  done
  for v in 1920 1920x 1920*1080 axb "1920 x 1080" 1x1 123456x1080 "" ; do
    gen --virtual-desktop "$v"; [[ $RC -ne 0 ]] || fail "[$v] accepted"
    assert_contains "$OUT" "--virtual-desktop"
  done
}

test_virtual_desktop_is_not_used_for_the_installer() {
  make_installer "install Program Files/FakeApp/FakeApp.exe"
  inst --virtual-desktop 1920x1080; assert_rc 0
  assert_file_has "$FAKE_WINE_LOG" "wine setup.exe"                      # the setup runs normally
  assert_file_lacks "$FAKE_WINE_LOG" "wine explorer /desktop=FakeApp,1920x1080 Z:"
  assert_eq "$(launcher_var "$(APP_FAKE)" VDESK)" "1920x1080"            # the installed program gets it
  : > "$FAKE_WINE_LOG"
  launch "$(APP_FAKE)"
  assert_file_has "$FAKE_WINE_LOG" "wine explorer /desktop=FakeApp,1920x1080 Z:"
}

test_virtual_desktop_in_run_mode() {
  dmg -e game.exe -d "$PROG" -n Demo --run --virtual-desktop 1280x720; assert_rc 0
  assert_file_has "$FAKE_WINE_LOG" "wine explorer /desktop=Demo,1280x720 Z:"
  assert_contains "$OUT" "virtual desktop"
}

test_virtual_desktop_survives_a_profile() {
  run /bin/bash "$SCRIPT" -e game.exe -d "$PROG" -n Demo -w "$WINE" --no-d3dcompiler --virtual-desktop 1600x900 --save-profile "$SB/p.profile"
  assert_rc 0
  assert_file_has "$SB/p.profile" "VDESK=1600x900"
  run /bin/bash "$SCRIPT" --profile "$SB/p.profile" -o "$OUTD"
  assert_eq "$(launcher_var "$(APP_DEMO)" VDESK)" "1600x900"
}

test_help_documents_virtual_desktop() {
  run /bin/bash "$SCRIPT" --help
  assert_contains "$OUT" "--virtual-desktop"
}

# --- options typed after --arg ---------------------------------------------------------------
# Regression: "--arg --env --arg WINEDLLOVERRIDES=... --arg --virtual-desktop --arg 1920x1080" (what the GUI builds
# from the Arguments field) sent everything to the game, which ignored it; nothing told the user.

test_an_option_of_dmgexe_after_arg_is_reported() {
  gen --arg --env --arg WINEDLLOVERRIDES=d3d11=d
  assert_rc 0
  assert_contains "$OUT" "warning: --arg --env"
  assert_contains "$OUT" "goes to the program"
}

test_every_dmgexe_option_after_arg_is_reported() {
  local o
  for o in --env --virtual-desktop --winver --gfx --winetricks --retina --no-vsync --fetch-wine --prefix-dir --run; do
    gen --arg "$o"
    assert_contains "$OUT" "warning: --arg $o" "[$o] not reported"
  done
}

test_the_reported_argument_is_still_passed_to_the_program() {
  gen --arg --env; launch "$(APP_DEMO)"
  assert_file_has "$FAKE_WINE_LOG" "  arg=--env"
}

test_ordinary_program_arguments_are_not_reported() {
  gen --arg --windowed --arg -fullscreen --arg "--width=1920" --arg 1920x1080
  assert_rc 0
  assert_not_contains "$OUT" "goes to the program"
}
