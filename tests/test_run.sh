# --run: launch right away without keeping an app.

test_run_launches_and_cleans_up() {
  dmg -e game.exe -d "$PROG" -n Demo --run
  assert_rc 0
  assert_contains "$OUT" "Running Demo"
  assert_contains "$OUT" "Program exited (code 0)"
  assert_file_has "$FAKE_WINE_LOG" "wine game.exe"
  assert_file_has "$FAKE_WINE_LOG" "cwd=$PROG"          # runs in place, nothing copied
  assert_eq "$(ls -A "$TMPDIR")" ""                        # throw-away app removed
  assert_missing "$PWD/Demo.app"
}

test_run_uses_the_apps_prefix() {
  dmg -e game.exe -d "$PROG" -n Demo --run
  assert_file "$(prefix_of Demo)/system.reg"
  assert_file_has "$FAKE_WINE_LOG" "env WINEPREFIX=$(prefix_of Demo)"
}

test_run_then_generated_app_share_prefix() {
  dmg -e game.exe -d "$PROG" -n Demo --run
  gen; assert_rc 0
  launch "$(APP_DEMO)"
  assert_count "$FAKE_WINE_LOG" "wine wineboot --init" 1
}

test_run_propagates_exit_code() {
  echo "exit 7" > "$PROG/game.exe"
  dmg -e game.exe -d "$PROG" -n Demo --run
  assert_rc 7
  assert_contains "$OUT" "Program exited (code 7)"
}

test_run_streams_the_launcher_output() {
  dmg -e game.exe -d "$PROG" -n Demo --run
  assert_contains "$OUT" "creating prefix at $(prefix_of Demo)"
  assert_contains "$OUT" "launching game.exe"
}

test_run_passes_args_and_settings() {
  dmg -e game.exe -d "$PROG" -n Demo --run --arg "--windowed" --env FOO=bar --no-msync
  assert_file_has "$FAKE_WINE_LOG" "  arg=--windowed"
  assert_file_has "$FAKE_WINE_LOG" "env FOO=bar"
  assert_file_lacks "$FAKE_WINE_LOG" "WINEMSYNC"
}

test_run_does_not_extract_icon() {
  dmg -e game.exe -d "$PROG" -n Demo --run
  assert_not_contains "$OUT" "no icon"
}
