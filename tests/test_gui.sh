# Only with: tests/run.sh --gui   (compiles the SwiftUI front-end; there are no UI tests)

test_gui_builds() {
  command -v swiftc >/dev/null || skip "swiftc not available"
  run bash "$ROOT/gui/build.sh" "$SB/gui"
  assert_rc 0
  assert_exec "$SB/gui/Dmgexe.app/Contents/MacOS/Dmgexe"
  # the app carries the same script that the tests exercise
  cmp -s "$SCRIPT" "$SB/gui/Dmgexe.app/Contents/Resources/dmgexe.sh" || fail "bundled dmgexe.sh differs from the project's"
}
