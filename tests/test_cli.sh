# Command-line parsing and validation (behaviour that existed before the installer mode).

test_help_lists_options() {
  run /bin/bash "$SCRIPT" --help
  assert_rc 0
  assert_contains "$OUT" "--fetch-wine"
  assert_contains "$OUT" "--winetricks"
  assert_contains "$OUT" "--profile"
}

test_missing_exe_fails() {
  run /bin/bash "$SCRIPT" -w "$WINE"
  assert_rc 1
  assert_contains "$OUT" "missing --exe"
}

test_unknown_option_fails() {
  run /bin/bash "$SCRIPT" --nope
  assert_rc 1
  assert_contains "$OUT" "unknown option: --nope"
}

test_invalid_gfx_rejected() {
  gen --gfx vulkan
  assert_rc 1
  assert_contains "$OUT" "--gfx must be"
}

test_invalid_fetch_wine_rejected() {
  gen --fetch-wine nightly
  assert_rc 1
  assert_contains "$OUT" "--fetch-wine must be"
}

test_exe_not_found() {
  dmg -e nothing.exe -d "$PROG" -o "$OUTD"
  assert_rc 1
  assert_contains "$OUT" "cannot find exe"
}

test_folder_not_found() {
  dmg -e game.exe -d "$SB/nope" -o "$OUTD"
  assert_rc 1
  assert_contains "$OUT" "folder not found"
}

test_exe_outside_folder_rejected() {
  echo x > "$SB/other.exe"
  dmg -e "$SB/other.exe" -d "$PROG" -o "$OUTD"
  assert_rc 1
  assert_contains "$OUT" "must be inside the program folder"
}

test_dir_defaults_to_exe_folder() {
  dmg -e "$PROG/game.exe" -n Demo -o "$OUTD"
  assert_rc 0
  assert_file "$(APP_DEMO)/Contents/Resources/program/game.exe"
  assert_file "$(APP_DEMO)/Contents/Resources/program/bin/tool.exe"
}

test_profile_not_found() {
  run /bin/bash "$SCRIPT" --profile "$SB/none.profile"
  assert_rc 1
  assert_contains "$OUT" "profile not found"
}

test_wine_folder_resolved_to_binary() {
  gen
  assert_rc 0
  assert_contains "$OUT" "Wine: $WINE/bin/wine64"
}

test_wine_bad_path_rejected() {
  run /bin/bash "$SCRIPT" -e game.exe -d "$PROG" -w "$SB/no-wine" --no-d3dcompiler -o "$OUTD"
  assert_rc 1
  assert_contains "$OUT" "cannot find wine in"
}

test_embed_without_wine_rejected() {
  # Only meaningful where no runtime is installed on the machine
  run /bin/bash "$SCRIPT" -e game.exe -d "$PROG" --embed-wine --no-d3dcompiler -o "$OUTD"
  [[ "$OUT" == *"Wine: "* ]] && skip "this machine has a Wine installed"
  assert_rc 1
  assert_contains "$OUT" "--embed-wine needs a Wine"
}

test_no_wine_only_warns() {
  run /bin/bash "$SCRIPT" -e game.exe -d "$PROG" -n Demo --no-d3dcompiler -o "$OUTD"
  [[ "$OUT" == *"Wine: "* ]] && skip "this machine has a Wine installed"
  assert_rc 0
  assert_contains "$OUT" "no runtime found"
  assert_file "$(APP_DEMO)/Contents/MacOS/launcher"
}

test_d3dmetal_without_runtime_warns() {
  run /bin/bash "$SCRIPT" -e game.exe -d "$PROG" --gfx d3dmetal --no-d3dcompiler -o "$OUTD"
  assert_contains "$OUT" "--gfx d3dmetal needs a Wine with D3DMetal"
}

# --- profiles ------------------------------------------------------------------------------

test_profile_roundtrip() {
  run /bin/bash "$SCRIPT" -e game.exe -d "$PROG" -n "My Game" --gfx dxvk --retina --no-vsync \
      --arg "--windowed" --arg "two words" --env FOO=bar --winetricks "vcrun2022" \
      --save-profile "$SB/p.profile"
  assert_rc 0
  assert_file "$SB/p.profile"
  assert_file_has "$SB/p.profile" 'GFX=dxvk'
  assert_file_has "$SB/p.profile" 'RETINA=1'
  assert_file_has "$SB/p.profile" 'VSYNC=0'
  # the profile is a bash file: sourcing it must restore the values
  ( source "$SB/p.profile"
    assert_eq "$NAME" "My Game"
    assert_eq "${ARGS[1]}" "two words"
    assert_eq "${ENVS[0]}" "FOO=bar"
    assert_eq "$WINETRICKS" "vcrun2022" ) || exit 1
}

test_profile_generates_app() {
  run /bin/bash "$SCRIPT" -e game.exe -d "$PROG" -n Demo -w "$WINE" --no-d3dcompiler --arg "--windowed" --save-profile "$SB/p.profile"
  assert_rc 0
  run /bin/bash "$SCRIPT" --profile "$SB/p.profile" -o "$OUTD"
  assert_rc 0
  assert_file "$(APP_DEMO)/Contents/MacOS/launcher"
  assert_file_has "$(launcher_of "$(APP_DEMO)")" '--windowed'
}

test_cli_overrides_profile() {
  run /bin/bash "$SCRIPT" -e game.exe -d "$PROG" -n FromProfile -w "$WINE" --no-d3dcompiler --save-profile "$SB/p.profile"
  run /bin/bash "$SCRIPT" --profile "$SB/p.profile" -n FromCli -o "$OUTD"
  assert_rc 0
  assert_dir "$OUTD/FromCli.app"
  assert_missing "$OUTD/FromProfile.app"
}

test_profile_relative_paths() {
  mkdir -p "$SB/box"; cp -R "$PROG" "$SB/box/game"
  cat > "$SB/box/x.profile" <<P
NAME="Rel"; DIR="./game"; EXE="game.exe"; WINE="$WINE"; D3DC=0
P
  run /bin/bash "$SCRIPT" --profile "$SB/box/x.profile" -o "$OUTD"
  assert_rc 0
  assert_file "$OUTD/Rel.app/Contents/Resources/program/game.exe"
}
