#!/bin/bash
# dmgexe.sh — package a Windows program as a macOS .app.
# The generated .app creates its own runtime prefix on first launch
# (~/Library/Application Support/<Name>/prefix).
#
# Usage:
#   dmgexe.sh -e <path/to/program.exe> -d <program folder> [options]
#
# Options:
#   -e, --exe PATH        Startup executable (absolute, or relative to --dir). Required.
#   -d, --dir PATH        Program folder. Defaults to the exe's folder.
#   -n, --name NAME       App name. Defaults to the exe's name.
#   -o, --out DIR         Output folder. Defaults to the current directory.
#   -w, --wine PATH       Runtime binary, or the folder of a runtime installation.
#                         Auto-detected when omitted.
#   -i, --icon FILE       Icon (.icns/.png/.ico). Extracted from the exe by default.
#       --embed-wine      Copy the runtime into the .app (self-contained, but larger).
#       --fetch-wine K    Download (and cache) a runtime build and embed it. K is one of:
#                           stable | devel | staging | gptk
#       --gfx G           Graphics backend: auto (default) | d3dmetal | dxvk | opengl
#                           d3dmetal: DX11/12 (use with --fetch-wine gptk)
#                           dxvk:     DX9/10/11 via Vulkan
#                           opengl:   OpenGL 4.6 compatibility profile rendered in software (slow)
#       --profile FILE    Load settings from a profile file (see below). The command line wins.
#       --save-profile F  Save the current settings to a reusable profile and exit.
#       --run             Do not keep an app: build a throw-away launcher, run the program right
#                         away (output is streamed) and clean up when it exits. Uses the same
#                         prefix as the generated app would.
#       --link            Do not copy the program: the .app points to the original folder.
#       --arg ARG         Argument passed to the exe (repeatable).
#       --env K=V         Extra environment variable (repeatable).
#       --winetricks "v"  Winetricks verbs to install on first launch.
#       --no-d3dcompiler  Do not install the native d3dcompiler_47 (installed by default).
#       --retina          Enable Retina mode (sharper, slower).
#       --no-msync        Disable MSYNC/ESYNC.
#       --win32           32-bit prefix (WINEARCH=win32; old runtimes only).
#   -h, --help            Show this help.
#
# Profile (a bash file; every variable is optional, paths are relative to the profile):
#   NAME="My Program"; DIR="./program"; EXE="bin/program.exe"; FETCH=gptk; GFX=d3dmetal
#   ARGS=(--windowed); ENVS=(WINEDEBUG=-all); WINETRICKS="vcrun2022"; RETINA=1

set -euo pipefail

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

EXE="" DIR="" NAME="" OUT="$PWD" WINE="" ICON="" EMBED=0 LINK=0
RUN_NOW=0 RETINA=0 MSYNC=1 WIN32=0 D3DC=1 WINETRICKS="" FETCH="" GFX="auto" SAVE_PROFILE=""
ARGS=() ENVS=()

# Profile: loaded before the command line so the latter can override it
PROFILE=""
for ((i=1; i<=$#; i++)); do
  [[ "${!i}" == --profile ]] && { j=$((i+1)); PROFILE="${!j:-}"; }
done
if [[ -n "$PROFILE" ]]; then
  [[ -f "$PROFILE" ]] || die "profile not found: $PROFILE"
  PROFILE_DIR="$(cd "$(dirname "$PROFILE")" && pwd)"
  # shellcheck disable=SC1090
  source "$PROFILE"
  for v in DIR ICON WINE OUT; do
    val="${!v}"
    [[ -n "$val" && "$val" != /* && -e "$PROFILE_DIR/$val" ]] && printf -v "$v" '%s' "$PROFILE_DIR/$val"
  done
  if [[ -n "$EXE" && "$EXE" != /* && -z "$DIR" && -e "$PROFILE_DIR/$EXE" ]]; then EXE="$PROFILE_DIR/$EXE"; fi
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--exe)       EXE="${2:?}"; shift 2 ;;
    -d|--dir)       DIR="${2:?}"; shift 2 ;;
    -n|--name)      NAME="${2:?}"; shift 2 ;;
    -o|--out)       OUT="${2:?}"; shift 2 ;;
    -w|--wine)      WINE="${2:?}"; shift 2 ;;
    -i|--icon)      ICON="${2:?}"; shift 2 ;;
    --embed-wine)   EMBED=1; shift ;;
    --fetch-wine)   FETCH="${2:?}"; shift 2 ;;
    --gfx)          GFX="${2:?}"; shift 2 ;;
    --profile)      shift 2 ;;
    --save-profile) SAVE_PROFILE="${2:?}"; shift 2 ;;
    --run)          RUN_NOW=1; shift ;;
    --link)         LINK=1; shift ;;
    --arg)          ARGS+=("${2:?}"); shift 2 ;;
    --env)          ENVS+=("${2:?}"); shift 2 ;;
    --winetricks)   WINETRICKS="${2:?}"; shift 2 ;;
    --retina)       RETINA=1; shift ;;
    --no-msync)     MSYNC=0; shift ;;
    --no-d3dcompiler) D3DC=0; shift ;;
    --win32)        WIN32=1; shift ;;
    -h|--help)      usage 0 ;;
    *)              echo "unknown option: $1" >&2; usage 1 ;;
  esac
done

[[ -n "$EXE" ]] || { echo "missing --exe" >&2; usage 1; }
case "$GFX" in auto|d3dmetal|dxvk|opengl) ;; *) die "--gfx must be auto, d3dmetal, dxvk or opengl";; esac
case "$FETCH" in ""|stable|devel|staging|gptk) ;; *) die "--fetch-wine must be stable, devel, staging or gptk";; esac
[[ "$GFX" == d3dmetal && -z "$FETCH" && -z "$WINE" ]] && echo "warning: --gfx d3dmetal needs a Wine with D3DMetal; consider --fetch-wine gptk" >&2

if [[ -n "$SAVE_PROFILE" ]]; then
  {
    echo "# Profile generated by dmgexe.sh"
    for v in NAME DIR EXE WINE ICON FETCH GFX EMBED LINK RETINA MSYNC WIN32 D3DC WINETRICKS; do
      printf '%s=%q\n' "$v" "${!v}"
    done
    printf 'ARGS=('; for a in "${ARGS[@]+"${ARGS[@]}"}"; do printf '%q ' "$a"; done; echo ')'
    printf 'ENVS=('; for a in "${ENVS[@]+"${ENVS[@]}"}"; do printf '%q ' "$a"; done; echo ')'
  } > "$SAVE_PROFILE"
  info "Profile saved to $SAVE_PROFILE"; exit 0
fi

# --- Resolve exe and folder -------------------------------------------------
if [[ -z "$DIR" ]]; then
  [[ -f "$EXE" ]] || die "exe not found: $EXE"
  DIR="$(dirname "$EXE")"
fi
[[ -d "$DIR" ]] || die "folder not found: $DIR"
DIR="$(cd "$DIR" && pwd)"
if [[ -f "$EXE" && "$EXE" = /* ]]; then
  EXE_ABS="$EXE"
elif [[ -f "$DIR/$EXE" ]]; then
  EXE_ABS="$DIR/$EXE"
elif [[ -f "$EXE" ]]; then
  EXE_ABS="$(cd "$(dirname "$EXE")" && pwd)/$(basename "$EXE")"
else
  die "cannot find exe '$EXE' (also looked in $DIR)"
fi
case "$EXE_ABS" in "$DIR"/*) ;; *) die "the exe must be inside the program folder ($DIR)";; esac
EXE_REL="${EXE_ABS#"$DIR"/}"
EXE_REL_WIN="${EXE_REL//\//\\}"

[[ $RUN_NOW -eq 1 ]] && { OUT="$(mktemp -d)"; LINK=1; }
[[ -n "$NAME" ]] || NAME="$(basename "$EXE_ABS" .exe)"
SLUG="$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
APP="$OUT/$NAME.app"

# --- Downloads (Gcenx) with cache -------------------------------------------
CACHE="${DMGEXE_CACHE:-$HOME/Library/Caches/dmgexe}"

# github_asset REPO REGEX -> prints "tag<TAB>name<TAB>url" of the first matching asset
github_asset() {
  curl -fsSL "https://api.github.com/repos/$1/releases?per_page=100" | python3 -I -c '
import json, re, sys
rx = re.compile(sys.argv[1])
for rel in json.load(sys.stdin):
    for a in rel.get("assets", []):
        if rx.search(a["name"]):
            print(rel["tag_name"], a["name"], a["browser_download_url"], sep="\t"); sys.exit(0)
sys.exit(1)' "$2"
}

# fetch_tarball REPO REGEX DESTNAME -> prints the extracted (cached) folder
fetch_tarball() {
  local repo="$1" rx="$2" label="$3" info tag name url dest
  info="$(github_asset "$repo" "$rx")" || die "no release asset in $repo matches $rx (offline, or GitHub rate limit?)"
  IFS=$'\t' read -r tag name url <<<"$info"
  dest="$CACHE/$label-$tag"
  if [[ ! -f "$dest/.ok" ]]; then
    mkdir -p "$dest"
    echo "==> Downloading $name ($tag)..." >&2
    curl -fL $([[ -t 2 ]] && echo --progress-bar || echo -sS) "$url" -o "$CACHE/$name.part" >&2 || die "download failed: $url"
    echo "==> Extracting..." >&2
    tar -xf "$CACHE/$name.part" -C "$dest" || die "extraction failed: $name"
    rm -f "$CACHE/$name.part"; touch "$dest/.ok"
  else
    echo "==> Using cache: $dest" >&2
  fi
  echo "$dest"
}

if [[ -n "$FETCH" ]]; then
  if [[ "$FETCH" == gptk ]]; then
    ENG="$(fetch_tarball Gcenx/game-porting-toolkit '^game-porting-toolkit-.*\.tar\.xz$' gptk)"
  else
    ENG="$(fetch_tarball Gcenx/macOS_Wine_builds "^wine-$FETCH-.*-osx64\.tar\.xz$" "wine-$FETCH")"
  fi
  WINE="$ENG"; EMBED=1
fi
[[ $RUN_NOW -eq 1 ]] && EMBED=0   # run in place: no need to copy Wine into a throw-away app

DXVK_DIR=""
if [[ "$GFX" == dxvk ]]; then
  DXVK_DIR="$(fetch_tarball Gcenx/DXVK-macOS '^dxvk-macOS-async-v[0-9.]+-[0-9]+\.tar\.gz$' dxvk)"
  # folder containing x64/ (and x32/)
  DXVK_DIR="$(dirname "$(find "$DXVK_DIR" -type d -name x64 | head -1)")"
  [[ -d "$DXVK_DIR/x64" ]] || die "downloaded DXVK has no x64 folder"
fi

MESA_DIR=""
if [[ "$GFX" == opengl ]]; then
  MESA_DIR="$(fetch_tarball pal1000/mesa-dist-win '^mesa3d-[0-9.]+-release-msvc\.7z$' mesa)"
  [[ -f "$MESA_DIR/x64/opengl32.dll" ]] || die "downloaded Mesa has no x64/opengl32.dll"
fi

# Native d3dcompiler_47 (same sources and hashes winetricks uses)
D3DC_DIR=""
if [[ $D3DC -eq 1 ]]; then
  D3DC_DIR="$CACHE/d3dcompiler_47"
  mkdir -p "$D3DC_DIR"
  fetch_dll() { # remote_file dest sha256
    local f="$D3DC_DIR/$2"
    if [[ ! -f "$f" ]] || [[ "$(shasum -a 256 "$f" | cut -d' ' -f1)" != "$3" ]]; then
      echo "==> Downloading $2..." >&2
      curl -fsSL "https://raw.githubusercontent.com/mozilla/fxc2/master/dll/$1" -o "$f" || die "download failed: $1"
      [[ "$(shasum -a 256 "$f" | cut -d' ' -f1)" == "$3" ]] || { rm -f "$f"; die "hash mismatch for $2"; }
    fi
  }
  fetch_dll d3dcompiler_47.dll    d3dcompiler_47_64.dll 4432bbd1a390874f3f0a503d45cc48d346abc3a8c0213c289f4b615bf0ee84f3
  fetch_dll d3dcompiler_47_32.dll d3dcompiler_47_32.dll 2ad0d4987fc4624566b190e747c9d95038443956ed816abfd1e2d389b5ec0851
fi

# --- Locate Wine ---------------------------------------------------------
# Given a binary or folder, prints the path of the wine binary (wine64 or wine).
find_wine_bin() {
  local p="$1" c
  if [[ -f "$p" && -x "$p" ]]; then echo "$p"; return 0; fi
  [[ -d "$p" ]] || return 1
  for c in bin/wine64 bin/wine; do
    [[ -x "$p/$c" ]] && { echo "$p/$c"; return 0; }
  done
  # limited search inside bundles (.app) and nested folders
  c="$(find "$p" -maxdepth 6 \( -path '*/bin/wine64' -o -path '*/bin/wine' \) -type f -perm -u+x 2>/dev/null | sort | head -1)"
  [[ -n "$c" ]] && { echo "$c"; return 0; }
  return 1
}

autodetect_wine() {
  local c b
  for c in "$CACHE"/*/ /Applications/Wine*.app /opt/homebrew /usr/local; do
    if b="$(find_wine_bin "${c%/}" 2>/dev/null)"; then echo "$b"; return 0; fi
  done
  command -v wine64 2>/dev/null || command -v wine 2>/dev/null || return 1
}

if [[ -n "$WINE" ]]; then
  WINE_BIN="$(find_wine_bin "$WINE")" || die "cannot find wine in: $WINE"
else
  WINE_BIN="$(autodetect_wine)" || WINE_BIN=""
fi
if [[ -z "$WINE_BIN" ]]; then
  if [[ $EMBED -eq 1 ]]; then
    die "--embed-wine needs a Wine to copy: pass one with --wine"
  fi
  echo "warning: no runtime found. The .app will still be generated and will look for one at launch." >&2
  echo "       Install a runtime or regenerate with --wine PATH." >&2
else
  WINE_BIN="$(cd "$(dirname "$WINE_BIN")" && pwd -P)/$(basename "$WINE_BIN")"
  info "Wine: $WINE_BIN"
fi
# Wine root = folder containing bin/
[[ -n "$WINE_BIN" ]] && WINE_ROOT="$(dirname "$(dirname "$WINE_BIN")")" || WINE_ROOT=""

# --- Create the .app structure -------------------------------------------
info "Creating $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ $LINK -eq 1 ]]; then
  PROGRAM_REF="$DIR"
  info "--link mode: the app will use $DIR"
else
  info "Copying the program (this may take a while)..."
  mkdir -p "$APP/Contents/Resources/program"
  # rsync: fast, keeps permissions; skips Finder junk
  rsync -a --exclude '.DS_Store' "$DIR"/ "$APP/Contents/Resources/program"/
  PROGRAM_REF=""
fi

WINE_REL=""
if [[ $EMBED -eq 1 ]]; then
  info "Copying Wine into the app..."
  mkdir -p "$APP/Contents/Resources/runtime"
  rsync -a "$WINE_ROOT"/ "$APP/Contents/Resources/runtime"/
  WINE_REL="runtime/bin/$(basename "$WINE_BIN")"
fi

if [[ -n "$DXVK_DIR" ]]; then
  info "Embedding DXVK..."
  mkdir -p "$APP/Contents/Resources/dxvk"
  rsync -a "$DXVK_DIR"/ "$APP/Contents/Resources/dxvk"/
fi

if [[ -n "$MESA_DIR" ]]; then
  info "Embedding the software OpenGL driver..."
  for a in x64 x86; do
    mkdir -p "$APP/Contents/Resources/mesa/$a"
    cp "$MESA_DIR/$a/opengl32.dll" "$MESA_DIR/$a/libgallium_wgl.dll" "$APP/Contents/Resources/mesa/$a"/ 2>/dev/null || true
  done
fi

if [[ -n "$D3DC_DIR" ]]; then
  mkdir -p "$APP/Contents/Resources/d3dcompiler"
  cp "$D3DC_DIR"/*.dll "$APP/Contents/Resources/d3dcompiler"/
fi

# --- Icon -----------------------------------------------------------------
make_icns_from_png() { # png -> icns
  local png="$1" out="$2" set; set="$(mktemp -d)/icon.iconset"; mkdir -p "$set"
  local s
  for s in 16 32 128 256 512; do
    sips -z $s $s "$png" --out "$set/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$png" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$set" -o "$out"
}

extract_exe_icon() { # exe -> png (largest icon)
  python3 -I - "$1" "$2" <<'PY'
import struct, sys
exe, out = sys.argv[1], sys.argv[2]
d = open(exe, 'rb').read()
u16 = lambda o: struct.unpack_from('<H', d, o)[0]
u32 = lambda o: struct.unpack_from('<I', d, o)[0]
pe = u32(0x3C)
assert d[pe:pe+4] == b'PE\0\0'
nsec = u16(pe+6); optsz = u16(pe+20); opt = pe+24
dd = opt + (96 if u16(opt) == 0x10b else 112)
rva, size = u32(dd+16), u32(dd+20)
assert rva, 'no resources'
secs = []
so = opt + optsz
for i in range(nsec):
    o = so + i*40
    secs.append((u32(o+12), max(u32(o+8), u32(o+16)), u32(o+20)))  # va, vsize, rawptr
def r2o(r):
    for va, vs, raw in secs:
        if va <= r < va+vs: return r-va+raw
    raise ValueError
base = r2o(rva)
def entries(off):
    n = u16(off+12) + u16(off+14)
    for i in range(n):
        nid, tgt = u32(off+16+i*8), u32(off+20+i*8)
        yield nid, (tgt & 0x7FFFFFFF if tgt & 0x80000000 else tgt), bool(tgt & 0x80000000)
def leaf(off, isdir):
    while isdir:
        _, off, isdir = next(entries(base+off))
    rv, sz = u32(base+off), u32(base+off+4)
    o = r2o(rv); return d[o:o+sz]
types = {nid: (t, sub) for nid, t, sub in entries(base)}
def items(tp):
    t, sub = types[tp]
    return {nid: leaf(tt, s) for nid, tt, s in entries(base+t)}
icons = items(3); group = next(iter(items(14).values()))
cnt = struct.unpack_from('<H', group, 4)[0]
best = None
for i in range(cnt):
    w, h, c, _, pl, bc, br, iid = struct.unpack_from('<BBBBHHIH', group, 6+i*14)
    w = w or 256
    if iid in icons and (best is None or (w, bc) > (best[0], best[1])):
        best = (w, bc, iid, h or 256)
w, bc, iid, h = best
data = icons[iid]
if data[:8] == b'\x89PNG\r\n\x1a\n':
    open(out, 'wb').write(data)
else:
    ico = struct.pack('<HHH', 0, 1, 1) + struct.pack('<BBBBHHII', w % 256, h % 256, 0, 0, 1, bc, len(data), 22) + data
    open(out + '.ico', 'wb').write(ico)
PY
  if [[ -f "$2.ico" ]]; then sips -s format png "$2.ico" --out "$2" >/dev/null 2>&1 || return 1; rm -f "$2.ico"; fi
  [[ -s "$2" ]]
}

ICNS="$APP/Contents/Resources/AppIcon.icns"
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
HAVE_ICON=0
if [[ -n "$ICON" ]]; then
  [[ -f "$ICON" ]] || die "icon not found: $ICON"
  case "$ICON" in
    *.icns) cp "$ICON" "$ICNS"; HAVE_ICON=1 ;;
    *)      sips -s format png "$ICON" --out "$TMPD/i.png" >/dev/null && make_icns_from_png "$TMPD/i.png" "$ICNS" && HAVE_ICON=1 ;;
  esac
elif [[ $RUN_NOW -eq 0 ]] && extract_exe_icon "$EXE_ABS" "$TMPD/exe.png" 2>/dev/null; then
  make_icns_from_png "$TMPD/exe.png" "$ICNS" && HAVE_ICON=1
fi
if [[ $RUN_NOW -eq 0 ]]; then
  [[ $HAVE_ICON -eq 1 ]] && info "Icon ready" || echo "warning: no icon (use --icon to provide one)" >&2
fi

# --- Info.plist ------------------------------------------------------------
xml() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$(xml "$NAME")</string>
  <key>CFBundleDisplayName</key><string>$(xml "$NAME")</string>
  <key>CFBundleIdentifier</key><string>com.dmgexe.$SLUG</string>
  <key>CFBundleExecutable</key><string>launcher</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict></plist>
PLIST

# --- Launcher --------------------------------------------------------------
q() { printf '%q' "$1"; }  # safe bash escaping
{
  echo '#!/bin/bash'
  echo '# Generated by dmgexe.sh'
  echo "APP_NAME=$(q "$NAME")"
  echo "SLUG=$(q "$SLUG")"
  echo "EXE_REL=$(q "$EXE_REL")"
  echo "EXE_REL_WIN=$(q "$EXE_REL_WIN")"
  echo "PROGRAM_REF=$(q "$PROGRAM_REF")"
  echo "WINE_REL=$(q "$WINE_REL")"
  echo "WINE_HINT=$(q "$WINE_BIN")"
  echo "RETINA=$RETINA MSYNC=$MSYNC WIN32=$WIN32"
  echo "WINETRICKS=$(q "$WINETRICKS")"
  echo "GFX=$(q "$GFX")"
  echo "D3DC=$D3DC"
  printf 'PROGRAM_ARGS=('; for a in "${ARGS[@]+"${ARGS[@]}"}"; do printf '%s ' "$(q "$a")"; done; echo ')'
  printf 'EXTRA_ENV=('; for a in "${ENVS[@]+"${ENVS[@]}"}"; do printf '%s ' "$(q "$a")"; done; echo ')'
  cat <<'LAUNCH'

RES="$(cd "$(dirname "$0")/../Resources" && pwd)"
SUPPORT="$HOME/Library/Application Support/$APP_NAME"
LOG="$SUPPORT/launcher.log"
mkdir -p "$SUPPORT"
if [[ -n "${DMGEXE_FOREGROUND:-}" ]]; then exec > >(tee -a "$LOG") 2>&1; else exec >>"$LOG" 2>&1; fi
echo "=== $(date) ==="

alert() { osascript -e "display dialog \"$1\" with title \"$APP_NAME\" buttons {\"OK\"} default button 1 with icon stop" >/dev/null 2>&1; }

# Program
if [[ -n "$PROGRAM_REF" ]]; then PROGRAM_DIR="$PROGRAM_REF"; else PROGRAM_DIR="$RES/program"; fi
[[ -f "$PROGRAM_DIR/$EXE_REL" ]] || { alert "Cannot find the program at: $PROGRAM_DIR"; exit 1; }

# Runtime: embedded > remembered path > auto-detection
WINE=""
if [[ -n "$WINE_REL" && -x "$RES/$WINE_REL" ]]; then WINE="$RES/$WINE_REL"
elif [[ -n "$WINE_HINT" && -x "$WINE_HINT" ]]; then WINE="$WINE_HINT"
else
  for c in \
    /Applications/Wine*.app/Contents/Resources/wine/bin/wine64 \
    /Applications/Wine*.app/Contents/Resources/wine/bin/wine \
    /opt/homebrew/bin/wine64 /opt/homebrew/bin/wine /usr/local/bin/wine64 /usr/local/bin/wine; do
    [[ -x "$c" ]] && { WINE="$c"; break; }
  done
fi
[[ -n "$WINE" ]] || { alert "No runtime was found. Install one or regenerate the app with --wine."; exit 1; }
export PATH="$(dirname "$WINE"):$PATH"

# The runtime builds are usually x86_64: run them under Rosetta on Apple Silicon
RUN=()
if [[ "$(uname -m)" == "arm64" ]] && file -b "$WINE" | grep -q x86_64 && ! file -b "$WINE" | grep -q arm64; then
  RUN=(arch -x86_64)
fi

export WINEPREFIX="$SUPPORT/prefix"
export WINEDEBUG="${WINEDEBUG:--all}"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-winemenubuilder.exe=d}"
[[ $WIN32 -eq 1 ]] && export WINEARCH=win32
if [[ $MSYNC -eq 1 ]]; then export WINEMSYNC=1 WINEESYNC=1; fi
export MTL_HUD_ENABLED="${MTL_HUD_ENABLED:-0}"
for kv in "${EXTRA_ENV[@]}"; do export "$kv"; done

# First launch: create the prefix
if [[ ! -f "$WINEPREFIX/system.reg" ]]; then
  echo "creating prefix at $WINEPREFIX with $WINE"
  osascript -e "display notification \"Preparing the Windows environment (first launch only)…\" with title \"$APP_NAME\"" >/dev/null 2>&1
  "${RUN[@]}" "$WINE" wineboot --init || { alert "Prefix creation failed. Check: $LOG"; exit 1; }
  "${RUN[@]}" "$(dirname "$WINE")/wineserver" -w 2>/dev/null
fi

# Retina
if [[ ! -f "$SUPPORT/.retina-$RETINA" ]]; then
  v=n; [[ $RETINA -eq 1 ]] && v=y
  "${RUN[@]}" "$WINE" reg add 'HKCU\Software\Wine\Mac Driver' /v RetinaMode /t REG_SZ /d "$v" /f
  rm -f "$SUPPORT"/.retina-*; touch "$SUPPORT/.retina-$RETINA"
fi

# Native d3dcompiler_47 (the bundled runtime's own cannot compile many HLSL shaders)
if [[ "$D3DC" == 1 && -d "$RES/d3dcompiler" ]]; then
  export WINEDLLOVERRIDES="d3dcompiler_47=n,b;$WINEDLLOVERRIDES"
  if [[ ! -f "$SUPPORT/.d3dcompiler-done" ]]; then
    echo "installing native d3dcompiler_47"
    cp -f "$RES/d3dcompiler/d3dcompiler_47_64.dll" "$WINEPREFIX/drive_c/windows/system32/d3dcompiler_47.dll"
    [[ -d "$WINEPREFIX/drive_c/windows/syswow64" ]] && cp -f "$RES/d3dcompiler/d3dcompiler_47_32.dll" "$WINEPREFIX/drive_c/windows/syswow64/d3dcompiler_47.dll"
    touch "$SUPPORT/.d3dcompiler-done"
  fi
fi

# Graphics backend
if [[ "$GFX" == dxvk && -d "$RES/dxvk" ]]; then
  export WINEDLLOVERRIDES="d3d9,d3d10core,d3d11,dxgi=n,b;$WINEDLLOVERRIDES"
  if [[ ! -f "$SUPPORT/.dxvk-done" ]]; then
    echo "installing DXVK into the prefix"
    [[ -d "$RES/dxvk/x64" ]] && cp -f "$RES/dxvk/x64/"*.dll "$WINEPREFIX/drive_c/windows/system32/"
    [[ -d "$RES/dxvk/x32" && -d "$WINEPREFIX/drive_c/windows/syswow64" ]] && cp -f "$RES/dxvk/x32/"*.dll "$WINEPREFIX/drive_c/windows/syswow64/"
    touch "$SUPPORT/.dxvk-done"
  fi
elif [[ "$GFX" == d3dmetal ]]; then
  export D3DM_ENABLE_METALFX="${D3DM_ENABLE_METALFX:-1}"
elif [[ "$GFX" == opengl && -d "$RES/mesa" ]]; then
  export WINEDLLOVERRIDES="opengl32=n,b;$WINEDLLOVERRIDES"
  export GALLIUM_DRIVER="${GALLIUM_DRIVER:-llvmpipe}"
  if [[ ! -f "$SUPPORT/.opengl-done" ]]; then
    echo "installing the software OpenGL driver"
    SYS64="$WINEPREFIX/drive_c/windows/system32"; SYS32="$WINEPREFIX/drive_c/windows/syswow64"
    [[ -f "$SYS64/opengl32.dll.orig" ]] || cp -f "$SYS64/opengl32.dll" "$SYS64/opengl32.dll.orig"
    cp -f "$RES/mesa/x64/opengl32.dll" "$RES/mesa/x64/libgallium_wgl.dll" "$SYS64/"
    if [[ -d "$SYS32" && -f "$RES/mesa/x86/opengl32.dll" ]]; then
      [[ -f "$SYS32/opengl32.dll.orig" ]] || cp -f "$SYS32/opengl32.dll" "$SYS32/opengl32.dll.orig"
      cp -f "$RES/mesa/x86/opengl32.dll" "$RES/mesa/x86/libgallium_wgl.dll" "$SYS32/"
    fi
    touch "$SUPPORT/.opengl-done"
  fi
fi

# Switching away from the software OpenGL driver: restore the original DLLs
if [[ "$GFX" != opengl && -f "$SUPPORT/.opengl-done" ]]; then
  for d in system32 syswow64; do
    D="$WINEPREFIX/drive_c/windows/$d"
    [[ -f "$D/opengl32.dll.orig" ]] && mv -f "$D/opengl32.dll.orig" "$D/opengl32.dll"
    rm -f "$D/libgallium_wgl.dll"
  done
  rm -f "$SUPPORT/.opengl-done"
fi

# Optional winetricks (once)
if [[ -n "$WINETRICKS" && ! -f "$SUPPORT/.winetricks-done" ]]; then
  WT="$(command -v winetricks || true)"
  if [[ -n "$WT" ]]; then
    osascript -e "display notification \"Installing dependencies ($WINETRICKS)…\" with title \"$APP_NAME\"" >/dev/null 2>&1
    # shellcheck disable=SC2086
    "${RUN[@]}" "$WT" -q $WINETRICKS && touch "$SUPPORT/.winetricks-done"
  else
    echo "winetricks is not installed; skipping ($WINETRICKS)"
  fi
fi

# Start the program from its folder
cd "$PROGRAM_DIR/$(dirname "$EXE_REL")" || exit 1
echo "launching $EXE_REL"
exec "${RUN[@]}" "$WINE" "$(basename "$EXE_REL")" "${PROGRAM_ARGS[@]}"
LAUNCH
} > "$APP/Contents/MacOS/launcher"
chmod +x "$APP/Contents/MacOS/launcher"

# --- Run mode: launch now, then remove the throw-away app ------------------
if [[ $RUN_NOW -eq 1 ]]; then
  trap 'rm -rf "$TMPD" "$OUT"' EXIT
  info "Running $NAME (Ctrl+C to quit)"
  stop_program() {
    kill "$CH" 2>/dev/null
    local ws; ws="$(dirname "$WINE_BIN")/wineserver"
    if [[ -x "$ws" ]]; then
      ( export WINEPREFIX="$HOME/Library/Application Support/$NAME/prefix"
        arch -x86_64 "$ws" -k || "$ws" -k ) 2>/dev/null
    fi
  }
  DMGEXE_FOREGROUND=1 "$APP/Contents/MacOS/launcher" & CH=$!
  trap stop_program TERM INT
  rc=0; wait "$CH" || rc=$?
  trap - TERM INT
  wait "$CH" 2>/dev/null || true
  sleep 0.5   # let the output pipe flush
  info "Program exited (code $rc)"
  exit "$rc"
fi

# --- Ad-hoc signing and quarantine cleanup ---------------------------------
xattr -cr "$APP" 2>/dev/null || true
if [[ $EMBED -eq 0 ]]; then
  codesign --force --deep -s - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc signing failed" >&2
else
  echo "warning: apps with an embedded runtime are not signed; if macOS blocks it, run: xattr -cr \"$APP\"" >&2
fi

info "Done: $APP"
du -sh "$APP" | awk '{print "    size: "$1}'
echo "    run log: ~/Library/Application Support/$NAME/launcher.log"
