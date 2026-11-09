# The DXVK branch of the launcher, and a few things seen in a real run of an old game with DXVK.
# Generating with --gfx dxvk downloads DXVK, so these tests turn a normal app into a DXVK one by hand
# (a stand-in DXVK folder, a runtime with Vulkan support and a MoltenVK that "is installed").

# dxvk_app [GEN ARGS...]: generate Demo, then make it a DXVK app
dxvk_app() {
  gen "$@"; assert_rc 0
  local app; app="$(APP_DEMO)"
  mkdir -p "$app/Contents/Resources/dxvk/x64"; echo dll > "$app/Contents/Resources/dxvk/x64/d3d11.dll"; echo dll > "$app/Contents/Resources/dxvk/x64/dxgi.dll"
  sed -i '' 's/^GFX=.*/GFX=dxvk/' "$(launcher_of "$app")"
  mkdir -p "$WINE/lib/wine/x86_64-unix"; : > "$WINE/lib/wine/x86_64-unix/winevulkan.so"; : > "$WINE/lib/libMoltenVK.dylib"
}

test_dxvk_branch_installs_the_dlls_once() {
  dxvk_app
  launch "$(APP_DEMO)"; assert_rc 0
  assert_file "$(prefix_of Demo)/drive_c/windows/system32/d3d11.dll"
  assert_file "$SUPPORT_ROOT/Demo/.dxvk-done"
  assert_file_has "$FAKE_WINE_LOG" "env WINEDLLOVERRIDES=d3d9,d3d10core,d3d11,dxgi=n,b;"
}

test_dxvk_needs_a_runtime_with_vulkan() {
  dxvk_app
  rm "$WINE/lib/wine/x86_64-unix/winevulkan.so"
  launch "$(APP_DEMO)"
  assert_rc 1
  assert_file_has "$FAKE_OSA_LOG" "DXVK does not work with this runtime"
}

test_dxvk_needs_moltenvk() {
  dxvk_app
  rm "$WINE/lib/libMoltenVK.dylib"
  # only when the machine has no MoltenVK of its own
  [[ -f /opt/homebrew/lib/libMoltenVK.dylib || -f /usr/local/lib/libMoltenVK.dylib ]] && skip "this machine has MoltenVK installed"
  launch "$(APP_DEMO)"
  assert_rc 1
  assert_file_has "$FAKE_OSA_LOG" "DXVK needs MoltenVK"
}

# --- --no-vsync -----------------------------------------------------------------------------
# Regression: the launcher used the DXVK_CONFIG variable, which the DXVK builds used here (1.10.x) do not read
# (they read DXVK_CONFIG_FILE only), so --no-vsync did nothing and the game kept presenting with FIFO.

test_no_vsync_writes_a_dxvk_config_file_and_points_dxvk_to_it() {
  dxvk_app --no-vsync
  launch "$(APP_DEMO)"; assert_rc 0
  assert_file "$SUPPORT_ROOT/Demo/dxvk.conf"
  assert_file_has "$SUPPORT_ROOT/Demo/dxvk.conf" "dxgi.syncInterval = 0"
  assert_file_has "$SUPPORT_ROOT/Demo/dxvk.conf" "d3d9.presentInterval = 0"
}

test_the_dxvk_config_path_is_one_that_windows_code_can_open() {
  # DXVK runs inside Wine: it needs a Windows path (Z: is the Mac's root), not a Unix one
  dxvk_app --no-vsync
  launch "$(APP_DEMO)"
  local expected="Z:${SUPPORT_ROOT//\//\\}\\Demo\\dxvk.conf"
  assert_file_has "$FAKE_WINE_LOG" "env DXVK_CONFIG_FILE=$expected"
}

test_vsync_on_leaves_no_dxvk_config() {
  dxvk_app
  launch "$(APP_DEMO)"
  assert_missing "$SUPPORT_ROOT/Demo/dxvk.conf"
  assert_file_lacks "$FAKE_WINE_LOG" "DXVK_CONFIG_FILE"
}

test_turning_vsync_back_on_removes_the_config() {
  dxvk_app --no-vsync; launch "$(APP_DEMO)"
  assert_file "$SUPPORT_ROOT/Demo/dxvk.conf"
  dxvk_app; : > "$FAKE_WINE_LOG"; launch "$(APP_DEMO)"
  assert_missing "$SUPPORT_ROOT/Demo/dxvk.conf"
  assert_file_lacks "$FAKE_WINE_LOG" "DXVK_CONFIG_FILE"
}

test_a_user_supplied_dxvk_config_file_is_respected() {
  dxvk_app --no-vsync --env 'DXVK_CONFIG_FILE=Z:\my\own.conf'
  launch "$(APP_DEMO)"
  assert_file_has "$FAKE_WINE_LOG" 'env DXVK_CONFIG_FILE=Z:\my\own.conf'
}

# --- log size ---------------------------------------------------------------------------------
# Regression: DXVK logs about 100 lines at "info" level for every process, and launcher.log is never emptied:
# one game left a 140 MB log.

test_dxvk_logs_warnings_only_by_default() {
  dxvk_app
  launch "$(APP_DEMO)"
  assert_file_has "$FAKE_WINE_LOG" "env DXVK_LOG_LEVEL=warn"
}

test_dxvk_log_level_can_be_changed() {
  dxvk_app --env DXVK_LOG_LEVEL=info
  launch "$(APP_DEMO)"
  assert_file_has "$FAKE_WINE_LOG" "env DXVK_LOG_LEVEL=info"
}

test_dxvk_log_level_is_not_set_for_other_backends() {
  gen; launch "$(APP_DEMO)"
  assert_file_lacks "$FAKE_WINE_LOG" "DXVK_LOG_LEVEL"
}

test_a_big_launcher_log_is_rotated() {
  gen
  mkdir -p "$SUPPORT_ROOT/Demo"
  head -c 6000000 /dev/zero | tr '\0' 'x' > "$SUPPORT_ROOT/Demo/launcher.log"
  launch "$(APP_DEMO)"; assert_rc 0
  assert_file "$SUPPORT_ROOT/Demo/launcher.log.old"
  [[ "$(stat -f %z "$SUPPORT_ROOT/Demo/launcher.log.old")" -ge 6000000 ]] || fail "the old log should be kept"
  [[ "$(stat -f %z "$SUPPORT_ROOT/Demo/launcher.log")" -lt 100000 ]] || fail "the new log should start small"
}

test_a_small_launcher_log_is_kept_and_appended_to() {
  gen
  launch "$(APP_DEMO)"; launch "$(APP_DEMO)"
  assert_missing "$SUPPORT_ROOT/Demo/launcher.log.old"
  assert_count "$SUPPORT_ROOT/Demo/launcher.log" "launching game.exe" 2
}

test_only_one_old_log_is_kept() {
  gen
  mkdir -p "$SUPPORT_ROOT/Demo"
  head -c 6000000 /dev/zero | tr '\0' 'a' > "$SUPPORT_ROOT/Demo/launcher.log"; launch "$(APP_DEMO)"
  head -c 6000000 /dev/zero | tr '\0' 'b' > "$SUPPORT_ROOT/Demo/launcher.log"; launch "$(APP_DEMO)"
  assert_eq "$(ls "$SUPPORT_ROOT/Demo" | grep -c 'launcher.log')" 2
  assert_eq "$(head -c 1 "$SUPPORT_ROOT/Demo/launcher.log.old")" "b"
}
