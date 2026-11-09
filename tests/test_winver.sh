# --winver: the Windows version Wine reports to the program.

REG_VERSION() { echo "wine reg add HKCU\\Software\\Wine /v Version /t REG_SZ /d $1 /f"; }

test_winver_accepts_the_usual_spellings() {
  local pair in out
  for pair in xp:winxp 7:win7 8:win8 8.1:win81 10:win10 11:win11 win10:win10 Win7:win7 "Windows 10:win10" windows-xp:winxp; do
    in="${pair%%:*}"; out="${pair##*:}"
    gen --winver "$in"
    [[ $RC -eq 0 ]] || fail "[$in] rejected: $OUT"
    assert_eq "$(launcher_var "$(APP_DEMO)" WINVER)" "$out" "--winver $in"
  done
}

test_winver_rejects_unknown_versions() {
  local v
  for v in 95 12 vista banana; do
    gen --winver "$v"
    assert_rc 1
    assert_contains "$OUT" "--winver must be"
  done
}

test_no_winver_leaves_the_runtime_default() {
  gen; launch "$(APP_DEMO)"
  assert_eq "$(launcher_var "$(APP_DEMO)" WINVER)" ""
  assert_file_lacks "$FAKE_WINE_LOG" "/v Version"
  assert_file_lacks "$FAKE_WINE_LOG" "reg delete"
}

test_winver_is_written_to_the_prefix_before_the_program_runs() {
  gen --winver 10; launch "$(APP_DEMO)"; assert_rc 0
  assert_file_has "$FAKE_WINE_LOG" "$(REG_VERSION win10)"
  assert_file "$SUPPORT_ROOT/Demo/.winver-win10"
  local reg run
  reg="$(grep -n "/v Version" "$FAKE_WINE_LOG" | head -1 | cut -d: -f1)"
  run="$(grep -n "^wine game.exe" "$FAKE_WINE_LOG" | head -1 | cut -d: -f1)"
  [[ -n "$reg" && -n "$run" && $reg -lt $run ]] || fail "the version must be set before the program starts"
}

test_winver_is_written_only_once() {
  gen --winver 7; launch "$(APP_DEMO)"; launch "$(APP_DEMO)"; launch "$(APP_DEMO)"
  assert_count "$FAKE_WINE_LOG" "wine reg add HKCU\\Software\\Wine /v Version" 1
}

test_changing_the_winver_rewrites_it() {
  gen --winver 7; launch "$(APP_DEMO)"
  gen --winver xp; launch "$(APP_DEMO)"
  assert_file_has "$FAKE_WINE_LOG" "$(REG_VERSION win7)"
  assert_file_has "$FAKE_WINE_LOG" "$(REG_VERSION winxp)"
  assert_file "$SUPPORT_ROOT/Demo/.winver-winxp"
  assert_missing "$SUPPORT_ROOT/Demo/.winver-win7"
}

test_going_back_to_the_default_removes_the_version() {
  gen --winver 10; launch "$(APP_DEMO)"
  gen; launch "$(APP_DEMO)"
  assert_file_has "$FAKE_WINE_LOG" 'wine reg delete HKCU\Software\Wine /v Version /f'
  assert_missing "$SUPPORT_ROOT/Demo/.winver-win10"
  launch "$(APP_DEMO)"
  assert_count "$FAKE_WINE_LOG" "wine reg delete" 1
}

test_winver_does_not_disturb_retina() {
  gen --winver 10 --retina; launch "$(APP_DEMO)"
  assert_file_has "$FAKE_WINE_LOG" 'RetinaMode /t REG_SZ /d y /f'
  assert_file_has "$FAKE_WINE_LOG" "$(REG_VERSION win10)"
}

test_winver_in_run_mode() {
  dmg -e game.exe -d "$PROG" -n Demo --run --winver 7
  assert_rc 0
  assert_file_has "$FAKE_WINE_LOG" "$(REG_VERSION win7)"
}

test_winver_applies_before_the_installer_and_to_the_installed_app() {
  make_installer "install Program Files/FakeApp/FakeApp.exe"
  inst --winver xp; assert_rc 0
  local reg run
  reg="$(grep -n "/v Version" "$FAKE_WINE_LOG" | head -1 | cut -d: -f1)"
  run="$(grep -n "^wine setup.exe" "$FAKE_WINE_LOG" | head -1 | cut -d: -f1)"
  [[ -n "$reg" && -n "$run" && $reg -lt $run ]] || fail "the installer must already see the chosen version"
  assert_eq "$(launcher_var "$(APP_FAKE)" WINVER)" "winxp"
  launch "$(APP_FAKE)"
  assert_count "$FAKE_WINE_LOG" "wine reg add HKCU\\Software\\Wine /v Version" 1      # not repeated by the app
}

test_winver_roundtrips_through_a_profile() {
  run /bin/bash "$SCRIPT" -e game.exe -d "$PROG" -n Demo -w "$WINE" --no-d3dcompiler --winver 8.1 --save-profile "$SB/p.profile"
  assert_rc 0
  assert_file_has "$SB/p.profile" "WINVER=win81"
  run /bin/bash "$SCRIPT" --profile "$SB/p.profile" -o "$OUTD"
  assert_rc 0
  assert_eq "$(launcher_var "$(APP_DEMO)" WINVER)" "win81"
}

test_winver_11_without_gptk_does_not_warn() {
  gen --winver 11
  assert_rc 0
  assert_not_contains "$OUT" "may not know Windows 11"
}

test_help_documents_winver() {
  run /bin/bash "$SCRIPT" --help
  assert_contains "$OUT" "--winver"
}
