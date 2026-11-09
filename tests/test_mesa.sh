# --gfx opengl: Mesa comes from GitHub releases. Some releases are published without opengl32.dll (26.2.6).

# fake_mesa DIR [with_gl]: a Mesa folder layout
mk_mesa_tar() { # mk_mesa_tar OUTFILE WITH_GL
  local t="$SB/mesa-src-$(basename "$1")"; mkdir -p "$t/x64" "$t/x86"
  echo d > "$t/x64/d3d10warp.dll"
  if [[ "$2" == 1 ]]; then for a in x64 x86; do echo gl > "$t/$a/opengl32.dll"; echo g > "$t/$a/libgallium_wgl.dll"; done; fi
  tar -cf "$1" -C "$t" .
}

# A fake curl serving a GitHub API answer with two Mesa releases (newest: no opengl32.dll) and their archives.
fake_github() {
  mk_mesa_tar "$SB/new.7z" 0; mk_mesa_tar "$SB/old.7z" 1
  cat > "$SB/fakebin/curl" <<CURL
#!/bin/bash
out=""; url=""
while [[ \$# -gt 0 ]]; do case "\$1" in -o) out="\$2"; shift;; http*) url="\$1";; esac; shift; done
case "\$url" in
  *api.github.com*) echo '[{"tag_name":"26.2.6","assets":[{"name":"mesa3d-26.2.6-release-msvc.7z","browser_download_url":"https://x/new.7z"}]},{"tag_name":"26.2.5","assets":[{"name":"mesa3d-26.2.5-release-msvc.7z","browser_download_url":"https://x/old.7z"}]}]';;
  *new.7z) cp "$SB/new.7z" "\$out";;
  *old.7z) cp "$SB/old.7z" "\$out";;
  *) exit 22;;
esac
CURL
  chmod +x "$SB/fakebin/curl"
}

test_opengl_skips_a_mesa_release_without_opengl32() {
  fake_github
  gen --gfx opengl; assert_rc 0
  assert_file "$(APP_DEMO)/Contents/Resources/mesa/x64/opengl32.dll"
  assert_contains "$OUT" "no opengl32.dll"
}

test_opengl_uses_a_cached_mesa_when_github_is_unreachable() {
  printf '#!/bin/bash\nexit 22\n' > "$SB/fakebin/curl"; chmod +x "$SB/fakebin/curl"
  mkdir -p "$DMGEXE_CACHE/mesa-26.2.5/x64" "$DMGEXE_CACHE/mesa-26.2.6/x64"
  echo gl > "$DMGEXE_CACHE/mesa-26.2.5/x64/opengl32.dll"; echo g > "$DMGEXE_CACHE/mesa-26.2.5/x64/libgallium_wgl.dll"
  gen --gfx opengl; assert_rc 0
  assert_file "$(APP_DEMO)/Contents/Resources/mesa/x64/opengl32.dll"
}

test_opengl_fails_clearly_when_no_mesa_is_usable() {
  printf '#!/bin/bash\nexit 22\n' > "$SB/fakebin/curl"; chmod +x "$SB/fakebin/curl"
  gen --gfx opengl; assert_rc 1
  assert_contains "$OUT" "no usable Mesa"
}
