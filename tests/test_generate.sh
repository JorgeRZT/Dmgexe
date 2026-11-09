# Generating the .app bundle.

test_bundle_structure() {
  gen
  assert_rc 0
  local app; app="$(APP_DEMO)"
  assert_exec "$app/Contents/MacOS/launcher"
  assert_file "$app/Contents/Info.plist"
  plutil -lint "$app/Contents/Info.plist" >/dev/null || fail "Info.plist is not valid"
  assert_file "$app/Contents/Resources/program/game.exe"
  assert_file "$app/Contents/Resources/program/bin/tool.exe"
  assert_file "$app/Contents/Resources/program/data/level1.dat"
  assert_missing "$app/Contents/Resources/program/.DS_Store"
  assert_missing "$app/Contents/Resources/runtime"
  assert_contains "$OUT" "Done: $app"
}

test_default_name_from_exe() {
  dmg -e game.exe -d "$PROG" -o "$OUTD"
  assert_rc 0
  assert_dir "$OUTD/game.app"
}

test_plist_identity_and_escaping() {
  dmg -e game.exe -d "$PROG" -n "Tom & Jerry <1>" -o "$OUTD"
  assert_rc 0
  local p="$OUTD/Tom & Jerry <1>.app/Contents/Info.plist"
  plutil -lint "$p" >/dev/null || fail "Info.plist is not valid"
  assert_eq "$(plutil -extract CFBundleName raw "$p")" "Tom & Jerry <1>"
  assert_eq "$(plutil -extract CFBundleIdentifier raw "$p")" "com.dmgexe.Tom-Jerry-1"
  assert_eq "$(plutil -extract CFBundleExecutable raw "$p")" "launcher"
}

test_regenerating_replaces_app() {
  gen; assert_rc 0
  echo stale > "$(APP_DEMO)/Contents/Resources/stale.txt"
  gen; assert_rc 0
  assert_missing "$(APP_DEMO)/Contents/Resources/stale.txt"
}

test_link_mode_does_not_copy() {
  gen --link
  assert_rc 0
  assert_missing "$(APP_DEMO)/Contents/Resources/program"
  assert_file_has "$(launcher_of "$(APP_DEMO)")" "PROGRAM_REF=$PROG"
  assert_contains "$OUT" "--link mode"
}

test_copy_mode_has_empty_program_ref() {
  gen
  assert_file_has "$(launcher_of "$(APP_DEMO)")" "PROGRAM_REF=''"
}

test_exe_in_subfolder() {
  dmg -e bin/tool.exe -d "$PROG" -n Demo -o "$OUTD"
  assert_rc 0
  assert_file_has "$(launcher_of "$(APP_DEMO)")" "EXE_REL=bin/tool.exe"
  assert_file_has "$(launcher_of "$(APP_DEMO)")" 'EXE_REL_WIN=bin\\tool.exe'
}

test_embed_wine_copies_runtime() {
  gen --embed-wine
  assert_rc 0
  assert_exec "$(APP_DEMO)/Contents/Resources/runtime/bin/wine64"
  assert_file_has "$(launcher_of "$(APP_DEMO)")" "WINE_REL=runtime/bin/wine64"
  assert_contains "$OUT" "not signed"
}

test_not_embedded_remembers_wine_path() {
  gen
  assert_file_has "$(launcher_of "$(APP_DEMO)")" "WINE_REL=''"
  assert_file_has "$(launcher_of "$(APP_DEMO)")" "WINE_HINT=$WINE/bin/wine64"
}

test_png_icon_becomes_icns() {
  # 1x1 PNG
  echo 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' | base64 -d > "$SB/i.png"
  gen --icon "$SB/i.png"
  assert_rc 0
  assert_file "$(APP_DEMO)/Contents/Resources/AppIcon.icns"
  assert_contains "$OUT" "Icon ready"
}

test_missing_icon_file_rejected() {
  gen --icon "$SB/none.png"
  assert_rc 1
  assert_contains "$OUT" "icon not found"
}

test_unreadable_exe_icon_only_warns() {
  gen
  assert_rc 0
  assert_contains "$OUT" "no icon"
}

test_launcher_settings_baked_in() {
  gen --arg "--windowed" --arg "two words" --env FOO=bar --winetricks "vcrun2022 d3dx9" \
      --retina --no-msync --no-esync --no-vsync --win32 --gfx d3dmetal
  assert_rc 0
  local l; l="$(launcher_of "$(APP_DEMO)")"
  assert_file_has "$l" "RETINA=1 MSYNC=0 ESYNC=0 VSYNC=0 WIN32=1"
  assert_eq "$(launcher_var "$(APP_DEMO)" WINETRICKS)" "vcrun2022 d3dx9"
  assert_file_has "$l" "GFX=d3dmetal"
  assert_file_has "$l" "D3DC=0"
  assert_file_has "$l" "--windowed two\\ words"
  assert_file_has "$l" "FOO=bar"
  /bin/bash -n "$l" || fail "the launcher has a syntax error"
}

test_launcher_defaults() {
  gen
  local l; l="$(launcher_of "$(APP_DEMO)")"
  assert_file_has "$l" "RETINA=0 MSYNC=1 ESYNC=1 VSYNC=1 WIN32=0"
  assert_file_has "$l" "GFX=auto"
  /bin/bash -n "$l" || fail "the launcher has a syntax error"
}

test_no_d3dcompiler_skips_dlls() {
  gen
  assert_missing "$(APP_DEMO)/Contents/Resources/d3dcompiler"
}

test_app_name_with_special_characters_in_launcher() {
  dmg -e game.exe -d "$PROG" -n "It's \"odd\" \$HOME" -o "$OUTD"
  assert_rc 0
  local l="$OUTD/It's \"odd\" \$HOME.app/Contents/MacOS/launcher"
  /bin/bash -n "$l" || fail "the launcher has a syntax error"
  ( eval "$(grep '^APP_NAME=' "$l")"; assert_eq "$APP_NAME" "It's \"odd\" \$HOME" ) || exit 1
}
