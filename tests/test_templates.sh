# Prefix templates: the first prefix built with a runtime + list of winetricks components is kept and cloned.

TEMPLATES_DIR() { echo "$DMGEXE_CACHE/prefix-templates"; }
one_template() { ls -d "$(TEMPLATES_DIR)"/*/ 2>/dev/null | head -1 | sed 's|/$||'; }
count_templates() { ls -d "$(TEMPLATES_DIR)"/*/ 2>/dev/null | wc -l | tr -d ' '; }
# gen_as NAME ARGS...: another app (same program) with its own prefix
gen_as() { local n="$1"; shift; dmg -e game.exe -d "$PROG" -n "$n" -o "$OUTD" "$@"; }

test_first_prefix_with_components_is_saved_as_a_template() {
  gen --winetricks "vcrun2008 d3dx9"; assert_rc 0
  launch "$(APP_DEMO)"; assert_rc 0
  assert_eq "$(count_templates)" 1
  local t; t="$(one_template)"
  assert_file "$t/.ok"
  assert_file "$t/prefix/system.reg"
  assert_file "$t/prefix/drive_c/windows/system32/vcrun2008.dll"
  assert_contains "$(cat "$t/info")" "d3dx9,vcrun2008"
  assert_contains "$(cat "$SUPPORT_ROOT/Demo/launcher.log")" "saved prefix template"
}

test_template_holds_the_clean_prefix_not_the_apps_own_changes() {
  gen --winetricks "vcrun2008" --winver 10 --retina; launch "$(APP_DEMO)"
  local t; t="$(one_template)"
  echo mine > "$(prefix_of Demo)/drive_c/saved-game.txt"
  assert_missing "$t/prefix/drive_c/saved-game.txt"
  assert_file_lacks "$t/prefix/winetricks.log" "game"
}

test_second_app_with_the_same_components_skips_winetricks_and_wineboot() {
  gen --winetricks "vcrun2008 d3dx9"; launch "$(APP_DEMO)"
  gen_as Other --winetricks "vcrun2008 d3dx9"; assert_rc 0
  : > "$FAKE_WINE_LOG"; : > "$FAKE_TRICKS_LOG"
  launch "$OUTD/Other.app"; assert_rc 0
  assert_eq "$(cat "$FAKE_TRICKS_LOG")" ""                                   # winetricks not run again
  assert_file_lacks "$FAKE_WINE_LOG" "wineboot"                              # nor a new prefix initialised
  assert_file_has "$FAKE_WINE_LOG" "wine game.exe"
  assert_file "$(prefix_of Other)/drive_c/windows/system32/d3dx9.dll"        # but the components are there
  assert_file "$(prefix_of Other)/drive_c/windows/system32/vcrun2008.dll"
  assert_file "$SUPPORT_ROOT/Other/.winetricks-done"
  assert_contains "$(cat "$SUPPORT_ROOT/Other/launcher.log")" "from the saved template"
  assert_eq "$(count_templates)" 1
}

test_a_clone_is_independent_and_keeps_symlinks() {
  gen --winetricks "vcrun2008"; launch "$(APP_DEMO)"
  gen_as Other --winetricks "vcrun2008"; launch "$OUTD/Other.app"
  [[ -L "$(prefix_of Other)/dosdevices/c:" ]] || fail "dosdevices/c: should still be a symlink"
  echo mine > "$(prefix_of Other)/drive_c/other-only.txt"
  assert_missing "$(prefix_of Demo)/drive_c/other-only.txt"
  assert_missing "$(one_template)/prefix/drive_c/other-only.txt"
  assert_eq "$(readlink "$(prefix_of Other)/dosdevices/c:")" "../drive_c"
}

test_the_order_of_the_components_does_not_matter() {
  gen --winetricks "vcrun2008 d3dx9"; launch "$(APP_DEMO)"
  gen_as Other --winetricks "d3dx9 vcrun2008 d3dx9"; : > "$FAKE_TRICKS_LOG"
  launch "$OUTD/Other.app"
  assert_eq "$(cat "$FAKE_TRICKS_LOG")" ""
  assert_eq "$(count_templates)" 1
}

test_different_components_get_their_own_template() {
  gen --winetricks "vcrun2008"; launch "$(APP_DEMO)"
  gen_as Other --winetricks "vcrun2008 d3dx9"; : > "$FAKE_TRICKS_LOG"
  launch "$OUTD/Other.app"
  assert_file_has "$FAKE_TRICKS_LOG" "winetricks -q vcrun2008 d3dx9"          # it had to install
  assert_eq "$(count_templates)" 2
}

test_a_different_runtime_does_not_share_templates() {
  gen --winetricks "vcrun2008"; launch "$(APP_DEMO)"
  cp -R "$WINE" "$SB/wine2"; echo "# another build" >> "$SB/wine2/bin/wine64"
  run /bin/bash "$SCRIPT" -w "$SB/wine2" --no-d3dcompiler -e game.exe -d "$PROG" -n Other -o "$OUTD" --winetricks "vcrun2008"
  assert_rc 0
  : > "$FAKE_TRICKS_LOG"
  launch "$OUTD/Other.app"
  assert_file_has "$FAKE_TRICKS_LOG" "winetricks -q vcrun2008"
  assert_eq "$(count_templates)" 2
}

test_a_different_wine_version_does_not_share_templates() {
  gen --winetricks "vcrun2008"; launch "$(APP_DEMO)"
  gen_as Other --winetricks "vcrun2008"; : > "$FAKE_TRICKS_LOG"
  FAKE_WINE_VERSION=2.0 launch "$OUTD/Other.app"
  assert_file_has "$FAKE_TRICKS_LOG" "winetricks -q vcrun2008"
  assert_eq "$(count_templates)" 2
}

test_32_bit_prefixes_have_their_own_template() {
  gen --winetricks "vcrun2008"; launch "$(APP_DEMO)"
  gen_as Other --winetricks "vcrun2008" --win32; : > "$FAKE_TRICKS_LOG"
  launch "$OUTD/Other.app"
  assert_file_has "$FAKE_TRICKS_LOG" "winetricks -q vcrun2008"
}

test_no_template_option_saves_nothing() {
  gen --winetricks "vcrun2008" --no-template; launch "$(APP_DEMO)"
  assert_eq "$(count_templates)" 0
  assert_file "$(prefix_of Demo)/drive_c/windows/system32/vcrun2008.dll"      # the components were still installed
}

test_no_template_option_ignores_an_existing_template() {
  gen --winetricks "vcrun2008"; launch "$(APP_DEMO)"
  assert_eq "$(count_templates)" 1
  gen_as Other --winetricks "vcrun2008" --no-template; : > "$FAKE_TRICKS_LOG"
  launch "$OUTD/Other.app"
  assert_file_has "$FAKE_TRICKS_LOG" "winetricks -q vcrun2008"                # installed for real
}

test_no_components_no_template() {
  gen; launch "$(APP_DEMO)"
  assert_eq "$(count_templates)" 0
}

test_a_failed_winetricks_saves_nothing() {
  gen --winetricks "vcrun2008"
  FAKE_TRICKS_RC=1 launch "$(APP_DEMO)"
  assert_eq "$(count_templates)" 0
  assert_missing "$SUPPORT_ROOT/Demo/.winetricks-done"
}

test_a_prefix_that_already_existed_is_not_saved_as_a_template() {
  gen; launch "$(APP_DEMO)"                                                    # prefix exists, without components
  gen --winetricks "vcrun2008"; launch "$(APP_DEMO)"                           # components added later
  assert_eq "$(count_templates)" 0
  assert_file "$(prefix_of Demo)/drive_c/windows/system32/vcrun2008.dll"
}

test_template_is_taken_before_the_program_or_installer_touches_the_prefix() {
  make_installer "install Program Files/FakeApp/FakeApp.exe"
  inst --winetricks "vcrun2008"; assert_rc 0
  assert_eq "$(count_templates)" 1
  assert_missing "$(one_template)/prefix/drive_c/Program Files/FakeApp"
  assert_file "$(prefix_of FakeApp)/drive_c/Program Files/FakeApp/FakeApp.exe"
}

test_windows_version_and_retina_are_still_applied_to_a_clone() {
  gen --winetricks "vcrun2008"; launch "$(APP_DEMO)"
  gen_as Other --winetricks "vcrun2008" --winver 10 --retina; : > "$FAKE_WINE_LOG"
  launch "$OUTD/Other.app"
  assert_file_has "$FAKE_WINE_LOG" "/v Version /t REG_SZ /d win10"
  assert_file_has "$FAKE_WINE_LOG" "RetinaMode /t REG_SZ /d y /f"
}

test_clone_goes_to_a_prefix_dir_on_another_location() {
  gen --winetricks "vcrun2008"; launch "$(APP_DEMO)"
  gen_as Other --winetricks "vcrun2008" --prefix-dir "$SB/ext/Other"; : > "$FAKE_TRICKS_LOG"
  launch "$OUTD/Other.app"; assert_rc 0
  assert_eq "$(cat "$FAKE_TRICKS_LOG")" ""
  assert_file "$SB/ext/Other/drive_c/windows/system32/vcrun2008.dll"
}

test_a_new_prefix_forgets_stale_markers() {
  gen --winver 10 --retina; launch "$(APP_DEMO)"
  rm -rf "$(prefix_of Demo)"                                                   # prefix lost, markers remain
  : > "$FAKE_WINE_LOG"
  launch "$(APP_DEMO)"; assert_rc 0
  assert_file_has "$FAKE_WINE_LOG" "RetinaMode /t REG_SZ /d y /f"             # set up again, not skipped
  assert_file_has "$FAKE_WINE_LOG" "/v Version /t REG_SZ /d win10"
}

test_cloning_falls_back_to_copying_when_clones_are_not_possible() {
  gen --winetricks "vcrun2008"; launch "$(APP_DEMO)"
  gen_as Other --winetricks "vcrun2008"
  # a cp that refuses -c, like a copy between two volumes
  cat > "$SB/fakebin/cp" <<'CP'
#!/bin/bash
for a in "$@"; do case "$a" in -cRp) echo "cp: -c is not supported" >&2; exit 1;; esac; done
exec /bin/cp "$@"
CP
  chmod +x "$SB/fakebin/cp"; : > "$FAKE_WINE_LOG"
  launch "$OUTD/Other.app"; assert_rc 0
  assert_file "$(prefix_of Other)/drive_c/windows/system32/vcrun2008.dll"
  assert_file_lacks "$FAKE_WINE_LOG" "wine wineboot --init" "should not have rebuilt: only the first app did"
}

test_a_damaged_template_is_ignored() {
  gen --winetricks "vcrun2008"; launch "$(APP_DEMO)"
  rm -f "$(one_template)/.ok"                                                  # half-written / marked bad
  gen_as Other --winetricks "vcrun2008"; : > "$FAKE_TRICKS_LOG"
  launch "$OUTD/Other.app"; assert_rc 0
  assert_file_has "$FAKE_TRICKS_LOG" "winetricks -q vcrun2008"                # built normally...
  assert_file "$(one_template)/.ok"                                            # ...and the template repaired
}

# --- listing and deleting ---------------------------------------------------------------------

test_list_templates() {
  gen --winetricks "vcrun2008 d3dx9"; launch "$(APP_DEMO)"
  storage --list-templates; assert_rc 0
  local key; key="$(basename "$(one_template)")"
  local r; r="$(row template "$key")"
  [[ -n "$r" ]] || fail "template not listed: $OUT"
  assert_eq "$(field "$r" 5)" "d3dx9,vcrun2008"
  assert_contains "$(field "$r" 6)" "wine-fake"
  assert_eq "$(field "$r" 3)" "$(one_template)"
}

test_list_templates_is_empty_without_templates() {
  storage --list-templates; assert_rc 0
  assert_eq "$OUT" ""
}

test_delete_template_by_key_then_the_next_app_builds_again() {
  gen --winetricks "vcrun2008"; launch "$(APP_DEMO)"
  local key; key="$(basename "$(one_template)")"
  storage --delete-template "$key"; assert_rc 0
  assert_eq "$(count_templates)" 0
  gen_as Other --winetricks "vcrun2008"; : > "$FAKE_TRICKS_LOG"
  launch "$OUTD/Other.app"
  assert_file_has "$FAKE_TRICKS_LOG" "winetricks -q vcrun2008"
  assert_eq "$(count_templates)" 1
}

test_delete_all_templates() {
  gen --winetricks "vcrun2008"; launch "$(APP_DEMO)"
  gen_as Other --winetricks "d3dx9"; launch "$OUTD/Other.app"
  assert_eq "$(count_templates)" 2
  storage --delete-template all; assert_rc 0
  assert_eq "$(count_templates)" 0
  assert_dir "$(prefix_of Demo)"                                               # the prefixes themselves stay
}

test_delete_template_rejects_bad_keys() {
  gen --winetricks "vcrun2008"; launch "$(APP_DEMO)"
  local k
  for k in "../x" "a/b" ".." "ZZZ" ""; do
    storage --delete-template "$k"
    [[ $RC -ne 0 ]] || fail "[$k] accepted"
  done
  assert_eq "$(count_templates)" 1
  storage --delete-template 0123456789abcdef
  assert_rc 1
  assert_contains "$OUT" "no template with key"
}

test_deleting_a_template_does_not_touch_prefixes_made_from_it() {
  gen --winetricks "vcrun2008"; launch "$(APP_DEMO)"
  storage --delete-template all
  assert_file "$(prefix_of Demo)/drive_c/windows/system32/vcrun2008.dll"
}

test_help_documents_templates() {
  run /bin/bash "$SCRIPT" --help
  assert_contains "$OUT" "--no-template"
  assert_contains "$OUT" "--list-templates"
  assert_contains "$OUT" "--delete-template"
}

test_template_setting_is_baked_into_the_launcher() {
  gen
  assert_eq "$(launcher_var "$(APP_DEMO)" TEMPLATES)" 1
  gen --no-template
  assert_eq "$(launcher_var "$(APP_DEMO)" TEMPLATES)" 0
  assert_eq "$(launcher_var "$(APP_DEMO)" TEMPLATE_ROOT)" "$DMGEXE_CACHE/prefix-templates"
}

test_template_setting_survives_a_profile() {
  run /bin/bash "$SCRIPT" -e game.exe -d "$PROG" -n Demo -w "$WINE" --no-d3dcompiler --no-template --save-profile "$SB/p.profile"
  assert_file_has "$SB/p.profile" "TEMPLATES=0"
  run /bin/bash "$SCRIPT" --profile "$SB/p.profile" -o "$OUTD"
  assert_eq "$(launcher_var "$(APP_DEMO)" TEMPLATES)" 0
}
