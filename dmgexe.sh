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
#       --no-msync        Disable MSYNC.
#       --no-esync        Disable ESYNC.
#       --no-vsync        Disable VSync (DXVK only).
#       --win32           32-bit prefix (WINEARCH=win32; old runtimes only).
#       --install         -e is an installer (setup.exe), not the program. It is run inside the
#                         app's prefix, the program it installs is detected, and the app (or --run)
#                         then uses that installed program. If several programs show up, the
#                         installer's work is kept and the command exits with code 3 listing them:
#                         repeat it with --installed-exe (the installer is not run again).
#       --installed-exe P Program already installed in the prefix of --name (e.g.
#                         "C:\Program Files\App\app.exe" or "Program Files/App/app.exe"). Needs
#                         --name; -e/-d are not used. Nothing is copied: the app uses the prefix.
#       --winver V        Windows version Wine reports to the program: xp | 7 | 8 | 8.1 | 10 | 11
#                         (default: the runtime's own). Applied to the prefix, also before an
#                         installer runs. Old runtimes (GPTK) may not know 11.
#       --no-template     Do not reuse or save prefix templates (see below).
#       --prefix-dir DIR  Keep the Windows prefix (where installers put their files, and everything
#                         the program writes) in DIR instead of ~/Library/Application Support/<Name>/prefix.
#                         Use it to put the program on an external volume. The folder is created if
#                         needed; its volume must be connected whenever the app runs.
#       --wait            With --run, also wait for every process the program started
#                         (set by --install, for installers that launch a second stage).
#   -h, --help            Show this help.
#
# Templates: installing winetricks components (dotnet...) is slow. The first prefix built with a given
# runtime and list of components is saved as a template in <cache>/prefix-templates, and every later app
# asking for the same thing starts from a clone of it (an APFS clone: no extra disk space). Disable with
# --no-template.
#
# Storage (each prints and exits; machine-readable, tab separated):
#       --list-prefixes       prefix<TAB>name<TAB>path<TAB>size in KB<TAB>winetricks verbs installed
#       --list-cache          cache<TAB>verb<TAB>path<TAB>size in KB   (winetricks downloads)
#       --get-prefix-root     Print the folder where new prefixes are created (empty: ~/Library/Application Support).
#       --set-prefix-root D   Set that folder for every app (e.g. on an external drive); "default" resets it.
#                             Prefixes that already exist stay where they are (see --move-prefix).
#       --move-prefix NAME    Move the prefix of app NAME to that folder (refused while it is in use).
#       --list-wine           wine<TAB>pid<TAB>app<TAB>running time<TAB>command   (Wine processes running now)
#       --stop-wine T         Stop the Wine processes of app T, of every app ("all") or one ("pid:N").
#       --list-templates      template<TAB>key<TAB>path<TAB>size in KB<TAB>components<TAB>runtime<TAB>date
#       --delete-template K   Delete the prefix template with key K (or "all").
#       --delete-cache V      Delete the cached downloads of verb V (or "all"). They are downloaded again if needed.
#       --delete-prefix NAME  Delete the Windows prefix of app NAME (programs installed in it are lost; the
#                             app builds a new one at its next launch). Refused while it is in use.
#
# Profile (a bash file; every variable is optional, paths are relative to the profile):
#   NAME="My Program"; DIR="./program"; EXE="bin/program.exe"; FETCH=gptk; GFX=d3dmetal
#   ARGS=(--windowed); ENVS=(WINEDEBUG=-all); WINETRICKS="vcrun2022"; RETINA=1

set -euo pipefail

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

EXE="" DIR="" NAME="" OUT="$PWD" WINE="" ICON="" EMBED=0 LINK=0 INSTALL=0 INSTALLED_EXE="" WAIT_ALL=0 PREFIX_OVERRIDE="" WINVER="" TEMPLATES=1 STORAGE_CMD="" STORAGE_ARG=""
RUN_NOW=0 RETINA=0 MSYNC=1 ESYNC=1 VSYNC=1 WIN32=0 D3DC=1 WINETRICKS="" FETCH="" GFX="auto" SAVE_PROFILE=""
ARGS=() ENVS=()
ORIG_ARGS=("$@")
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

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
  for v in DIR ICON WINE OUT PREFIX_OVERRIDE; do
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
    --install)      INSTALL=1; shift ;;
    --installed-exe) INSTALLED_EXE="${2:?}"; shift 2 ;;
    --wait)         WAIT_ALL=1; shift ;;
    --prefix-dir)   PREFIX_OVERRIDE="${2:?}"; shift 2 ;;
    --winver)       WINVER="${2:?}"; shift 2 ;;
    --list-prefixes) STORAGE_CMD=list-prefixes; shift ;;
    --list-cache)   STORAGE_CMD=list-cache; shift ;;
    --list-templates) STORAGE_CMD=list-templates; shift ;;
    --get-prefix-root) STORAGE_CMD=get-prefix-root; shift ;;
    --set-prefix-root) STORAGE_CMD=set-prefix-root; STORAGE_ARG="${2-}"; shift 2 ;;
    --move-prefix)  STORAGE_CMD=move-prefix; STORAGE_ARG="${2:?}"; shift 2 ;;
    --list-wine)    STORAGE_CMD=list-wine; shift ;;
    --stop-wine)    STORAGE_CMD=stop-wine; STORAGE_ARG="${2:?}"; shift 2 ;;
    --delete-template) STORAGE_CMD=delete-template; STORAGE_ARG="${2:?}"; shift 2 ;;
    --no-template)  TEMPLATES=0; shift ;;
    --delete-cache) STORAGE_CMD=delete-cache; STORAGE_ARG="${2:?}"; shift 2 ;;
    --delete-prefix) STORAGE_CMD=delete-prefix; STORAGE_ARG="${2:?}"; shift 2 ;;
    --link)         LINK=1; shift ;;
    --arg)          ARGS+=("${2:?}"); shift 2 ;;
    --env)          ENVS+=("${2:?}"); shift 2 ;;
    --winetricks)   WINETRICKS="${2:?}"; shift 2 ;;
    --retina)       RETINA=1; shift ;;
    --no-msync)     MSYNC=0; shift ;;
    --no-esync)     ESYNC=0; shift ;;
    --no-vsync)     VSYNC=0; shift ;;
    --no-d3dcompiler) D3DC=0; shift ;;
    --win32)        WIN32=1; shift ;;
    -h|--help)      usage 0 ;;
    *)              echo "unknown option: $1" >&2; usage 1 ;;
  esac
done

# --- Storage: list / delete prefixes and winetricks downloads ------------------
APP_SUPPORT="$HOME/Library/Application Support"
CONFIG_FILE="$APP_SUPPORT/Dmgexe/config"

# the folder chosen for new prefixes (empty = the default place)
global_prefix_root() { [[ -f "$CONFIG_FILE" ]] && sed -n 's/^prefix_root=//p' "$CONFIG_FILE" | head -1 || true; }

# Where the prefix of app $1 is. Same rules as the launcher: an explicit --prefix-dir; else where the app
# already has it; else <global folder>/<name>/prefix; else the default place.
prefix_dir_of() {
  local rec="" root
  [[ -n "$PREFIX_OVERRIDE" ]] && { printf '%s' "$PREFIX_OVERRIDE"; return; }
  [[ -f "$APP_SUPPORT/$1/.prefix-path" ]] && rec="$(cat "$APP_SUPPORT/$1/.prefix-path")"
  if [[ -n "$rec" && -d "$rec" ]]; then printf '%s' "$rec"; return; fi
  if [[ -z "$rec" && -f "$APP_SUPPORT/$1/prefix/system.reg" ]]; then printf '%s' "$APP_SUPPORT/$1/prefix"; return; fi
  root="$(global_prefix_root)"
  if [[ -n "$root" ]]; then printf '%s' "$root/$1/prefix"; else printf '%s' "$APP_SUPPORT/$1/prefix"; fi
}

# every prefix of an app made by Dmgexe: prints "name<TAB>path"
# (When looking one up, let awk read it all: quitting early gives each_prefix a SIGPIPE and, with pipefail, kills the script.)
each_prefix() {
  local d name p
  for d in "$APP_SUPPORT"/*/; do
    d="${d%/}"; name="$(basename "$d")"
    if [[ -f "$d/.prefix-path" ]]; then p="$(cat "$d/.prefix-path")"   # written by the launcher (also for --prefix-dir)
    elif [[ -d "$d/prefix" ]]; then p="$d/prefix"
    else continue; fi
    printf '%s\t%s\n' "$name" "$p"
  done
}

# folders where winetricks keeps its downloads
cache_dirs() {
  local d
  for d in "${W_CACHE:-}" "${XDG_CACHE_HOME:+$XDG_CACHE_HOME/winetricks}" "$HOME/Library/Caches/winetricks" "$HOME/.cache/winetricks"; do
    [[ -n "$d" && -d "$d" ]] && printf '%s\n' "$d"
  done | awk '!seen[$0]++'
}

template_root() { printf '%s' "${DMGEXE_CACHE:-$HOME/Library/Caches/dmgexe}/prefix-templates"; }

# wine_sessions: one line per Wine process running now: pid<TAB>prefix path (empty if unknown)<TAB>running time<TAB>
# folder of its Wine binaries<TAB>what it runs. A process belongs to a prefix when it has its working directory
# or any open file inside it, or the files of that prefix's wineserver. (A process's environment cannot be used:
# macOS hides it for translated (Rosetta) programs, which is what the Wine builds are.)
wine_sessions() {
  each_prefix | python3 -I -c '
import os, subprocess, sys
known = [l.rstrip("\n").split("\t") for l in sys.stdin if "\t" in l]
names = {"wine64-preloader", "wine-preloader", "wineserver", "wine64", "wine"}
only = os.environ.get("DMGEXE_PROCESS_ROOT", "")
ps = subprocess.run(["ps", "-Axo", "pid=,etime=,comm="], capture_output=True, text=True).stdout
procs = {}
for line in ps.splitlines():
    parts = line.split(None, 2)
    if len(parts) == 3 and os.path.basename(parts[2]) in names:
        # DMGEXE_PROCESS_ROOT limits the search to executables under that folder (the test-suite sets it,
        # so that it can never see, and stop, the Wine programs you are really running)
        if only and not parts[2].startswith(only): continue
        procs[parts[0]] = (parts[1], parts[2])
if not procs: sys.exit(0)
pids = ",".join(procs)
cmds = {}
for line in subprocess.run(["ps", "-p", pids, "-o", "pid=,command="], capture_output=True, text=True).stdout.splitlines():
    p = line.split(None, 1)
    if len(p) == 2: cmds[p[0]] = p[1]
files = {}
cur = None
for line in subprocess.run(["lsof", "-p", pids, "-Fpn"], capture_output=True, text=True).stdout.splitlines():
    if line.startswith("p"): cur = line[1:]; files[cur] = []
    elif line.startswith("n") and cur: files[cur].append(line[1:])
servers = {}
for name, path in known:
    try:
        st = os.stat(path); servers["server-%x-%x" % (st.st_dev, st.st_ino)] = os.path.realpath(path)
    except OSError: pass
reals = [(os.path.realpath(path), path) for name, path in known]
for pid, (et, comm) in procs.items():
    found = ""
    for f in files.get(pid, []):
        rf = os.path.realpath(f) if f.startswith("/") else f
        for real, orig in reals:
            if rf == real or rf.startswith(real + "/"): found = orig; break
        if not found:
            for key, real in servers.items():
                if "/" + key + "/" in f:
                    found = next(o for r, o in reals if r == real); break
        if found: break
    cmd = cmds.get(pid, comm)
    shown = cmd[len(comm):].strip() if cmd.startswith(comm) else cmd
    print("\t".join([pid, found, et, os.path.dirname(comm), shown or os.path.basename(comm)]))
'
}

# true while a Wine process runs in the prefix $1
prefix_in_use() {
  local rows; rows="$(wine_sessions)" || true
  [[ "$rows" == *$'\t'"$1"$'\t'* ]]
}

# stop_wine TARGET: TARGET is an app name, "all" or "pid:N". First asks each prefix's wineserver to stop
# everything (-k), then terminates what is left, then kills what still ignores that.
stop_wine() {
  local target="$1" rows pid pfx et bindir shown nm sel="" ws servers="" n=0
  rows="$(wine_sessions)" || true
  while IFS=$'\t' read -r pid pfx et bindir shown; do
    [[ -n "$pid" ]] || continue
    nm="$(each_prefix | awk -F'\t' -v p="$pfx" '!f && $2 == p {print $1; f=1}')"
    case "$target" in
      all) ;;
      pid:*) [[ "$pid" == "${target#pid:}" ]] || continue ;;
      *) [[ -n "$pfx" && "$nm" == "$target" ]] || continue ;;
    esac
    sel="$sel $pid"; n=$((n+1))
    [[ -n "$pfx" && -x "$bindir/wineserver" && "$target" != pid:* ]] && servers="$servers$pfx"$'\t'"$bindir"$'\n'
  done <<< "$rows"
  [[ $n -gt 0 ]] || die "no Wine process matches '$target'"
  # polite: wineserver -k for each prefix involved
  while IFS=$'\t' read -r pfx bindir; do
    [[ -n "$pfx" ]] || continue
    ( export WINEPREFIX="$pfx"
      if [[ "$(uname -m)" == "arm64" ]] && file -b "$bindir/wineserver" | grep -q x86_64; then arch -x86_64 "$bindir/wineserver" -k
      else "$bindir/wineserver" -k; fi ) >/dev/null 2>&1 || true
  done < <(printf '%s' "$servers" | sort -u)
  local alive left i
  for pass in TERM KILL; do
    left=""
    for pid in $sel; do kill -0 "$pid" 2>/dev/null && left="$left $pid"; done
    [[ -n "$left" ]] || break
    [[ $pass == KILL ]] || sleep 1
    left=""; for pid in $sel; do kill -0 "$pid" 2>/dev/null && left="$left $pid"; done
    for pid in $left; do kill -"$pass" "$pid" 2>/dev/null || true; done
    for i in 1 2 3 4 5 6; do
      alive=""; for pid in $left; do kill -0 "$pid" 2>/dev/null && alive="$alive $pid"; done
      [[ -z "$alive" ]] && break; sleep 0.5
    done
  done
  left=""; for pid in $sel; do kill -0 "$pid" 2>/dev/null && left="$left $pid"; done
  [[ -z "$left" ]] || die "could not stop:$left"
  echo "stopped $n process(es)"
}

# move_prefix NAME: to <global folder>/NAME/prefix (or back to the default place when no folder is set)
move_prefix() {
  local name="$1" src root dst
  case "$name" in */*|.|..|"") die "invalid app name: $name";; esac
  src="$(each_prefix | awk -F'\t' -v n="$name" '!f && $1 == n {print $2; f=1}')"
  [[ -n "$src" ]] || die "no prefix found for '$name'"
  [[ -d "$src" ]] || die "the prefix of '$name' is not there ($src). Is its drive connected?"
  [[ ! -f "$APP_SUPPORT/$name/.prefix-pinned" ]] || die "'$name' has a fixed location (it was made with --prefix-dir / Install location)"
  root="$(global_prefix_root)"
  if [[ -n "$root" ]]; then dst="$root/$name/prefix"; else dst="$APP_SUPPORT/$name/prefix"; fi
  [[ "$src" != "$dst" ]] || die "'$name' is already in $dst"
  [[ ! -e "$dst" ]] || die "the destination already exists: $dst"
  prefix_in_use "$src" && die "the prefix of '$name' is in use: stop its programs first"
  mkdir -p "$(dirname "$dst")" 2>/dev/null || die "cannot create $(dirname "$dst") (is the volume connected?)"
  if [[ "$(stat -f %d "$src")" == "$(stat -f %d "$(dirname "$dst")")" ]]; then
    mv "$src" "$dst" || die "could not move $src"
  else
    cp -Rp "$src" "$dst" || { rm -rf "$dst"; die "copy to $dst failed; nothing was changed"; }
    rm -rf "$src"
  fi
  echo "$dst" > "$APP_SUPPORT/$name/.prefix-path"
  echo "moved: $src -> $dst"
}

storage_cmd() {
  local name path kb verbs d v pinned
  case "$STORAGE_CMD" in
    get-prefix-root) global_prefix_root ;;
    set-prefix-root)
      if [[ -z "$STORAGE_ARG" || "$STORAGE_ARG" == default ]]; then
        [[ -f "$CONFIG_FILE" ]] && { sed -i '' '/^prefix_root=/d' "$CONFIG_FILE"; }
        echo "new prefixes go to: $APP_SUPPORT/<name>/prefix (default)"
      else
        [[ "$STORAGE_ARG" == /* ]] || STORAGE_ARG="$PWD/$STORAGE_ARG"
        STORAGE_ARG="${STORAGE_ARG%/}"
        mkdir -p "$STORAGE_ARG" 2>/dev/null || die "cannot create $STORAGE_ARG (is the volume connected?)"
        mkdir -p "$(dirname "$CONFIG_FILE")"
        { [[ -f "$CONFIG_FILE" ]] && sed '/^prefix_root=/d' "$CONFIG_FILE"; echo "prefix_root=$STORAGE_ARG"; } > "$CONFIG_FILE.new" && mv "$CONFIG_FILE.new" "$CONFIG_FILE"
        echo "new prefixes go to: $STORAGE_ARG/<name>/prefix"
      fi ;;
    list-wine)
      local rows pid pfx et bindir shown nm
      rows="$(wine_sessions)" || true
      while IFS=$'\t' read -r pid pfx et bindir shown; do
        [[ -n "$pid" ]] || continue
        nm="(unknown)"
        if [[ -n "$pfx" ]]; then nm="$(each_prefix | awk -F'\t' -v p="$pfx" '!f && $2 == p {print $1; f=1}')"; fi
        printf 'wine\t%s\t%s\t%s\t%s\n' "$pid" "${nm:-(unknown)}" "$et" "$shown"
      done <<< "$rows" ;;
    stop-wine) stop_wine "$STORAGE_ARG" ;;
    move-prefix) move_prefix "$STORAGE_ARG" ;;
    list-prefixes)
      while IFS=$'\t' read -r name path; do
        [[ -d "$path" ]] || continue
        kb="$(du -sk "$path" 2>/dev/null | cut -f1)"
        verbs=""
        [[ -f "$path/winetricks.log" ]] && verbs="$(awk 'NF && !seen[$1]++ {printf "%s%s", (n++ ? "," : ""), $1}' "$path/winetricks.log")"
        pinned=0; [[ -f "$APP_SUPPORT/$name/.prefix-pinned" ]] && pinned=1
        printf 'prefix\t%s\t%s\t%s\t%s\t%s\n' "$name" "$path" "${kb:-0}" "$verbs" "$pinned"
      done < <(each_prefix) ;;
    list-cache)
      while IFS= read -r d; do
        for v in "$d"/*/; do
          [[ -d "$v" ]] || continue
          v="${v%/}"
          printf 'cache\t%s\t%s\t%s\n' "$(basename "$v")" "$v" "$(du -sk "$v" 2>/dev/null | cut -f1)"
        done
      done < <(cache_dirs) ;;
    list-templates)
      for d in "$(template_root)"/*/; do
        [[ -f "$d/.ok" ]] || continue
        d="${d%/}"
        IFS=$'\t' read -r verbs v date < "$d/info" || true
        printf 'template\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(basename "$d")" "$d" "$(du -sk "$d" 2>/dev/null | cut -f1)" "$verbs" "${v:-}" "${date:-}"
      done ;;
    delete-template)
      [[ "$STORAGE_ARG" == all || "$STORAGE_ARG" =~ ^[0-9a-f]+$ ]] || die "invalid template key: $STORAGE_ARG"
      local n=0
      for d in "$(template_root)"/*/; do
        [[ -d "$d" ]] || continue
        d="${d%/}"
        if [[ "$STORAGE_ARG" == all || "$(basename "$d")" == "$STORAGE_ARG" ]]; then rm -rf "$d"; n=$((n+1)); echo "deleted: $d"; fi
      done
      [[ $n -gt 0 || "$STORAGE_ARG" == all ]] || die "no template with key '$STORAGE_ARG'" ;;
    delete-cache)
      [[ "$STORAGE_ARG" == all || "$STORAGE_ARG" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid verb name: $STORAGE_ARG"
      [[ "$STORAGE_ARG" != . && "$STORAGE_ARG" != .. ]] || die "invalid verb name: $STORAGE_ARG"
      local found=0
      while IFS= read -r d; do
        for v in "$d"/*/; do
          [[ -d "$v" ]] || continue
          v="${v%/}"
          if [[ "$STORAGE_ARG" == all || "$(basename "$v")" == "$STORAGE_ARG" ]]; then rm -rf "$v"; found=1; echo "deleted: $v"; fi
        done
      done < <(cache_dirs)
      [[ $found -eq 1 || "$STORAGE_ARG" == all ]] || die "no cached downloads for '$STORAGE_ARG'" ;;
    delete-prefix)
      case "$STORAGE_ARG" in */*|.|..|"") die "invalid app name: $STORAGE_ARG";; esac
      path="$(each_prefix | awk -F'\t' -v n="$STORAGE_ARG" '!f && $1 == n {print $2; f=1}')"
      [[ -n "$path" ]] || die "no prefix found for '$STORAGE_ARG'"
      [[ -d "$path" ]] || die "the prefix of '$STORAGE_ARG' is not there ($path). Is its drive connected?"
      [[ -f "$path/system.reg" || -d "$path/drive_c" ]] || die "refusing to delete $path: it does not look like a Windows prefix"
      prefix_in_use "$path" && die "the prefix of '$STORAGE_ARG' is in use: close the program first"
      rm -rf "$path"
      # the markers say what was set up in it; without them the app sets everything up again at its next launch
      rm -f "$APP_SUPPORT/$STORAGE_ARG"/.winetricks-done "$APP_SUPPORT/$STORAGE_ARG"/.d3dcompiler-done \
            "$APP_SUPPORT/$STORAGE_ARG"/.dxvk-done "$APP_SUPPORT/$STORAGE_ARG"/.opengl-done \
            "$APP_SUPPORT/$STORAGE_ARG"/.retina-* "$APP_SUPPORT/$STORAGE_ARG"/.winver-* "$APP_SUPPORT/$STORAGE_ARG"/.prefix-path
      echo "deleted: $path" ;;
  esac
}
if [[ -n "$STORAGE_CMD" ]]; then storage_cmd; exit 0; fi

# The installer mode re-invokes this script for each stage (see "Installer mode" below)
case "${DMGEXE_INSTALL_STAGE:-}" in
  run)      INSTALL=0; INSTALLED_EXE=""; ARGS=() ;;   # stage 1: the installer is the "program"
  generate) INSTALL=0; EXE=""; DIR="" ;;               # stage 2: the program is already in the prefix
esac
if [[ $INSTALL -eq 1 ]]; then
  [[ -n "$EXE" ]] || { echo "missing --exe (the installer)" >&2; usage 1; }
elif [[ -z "$EXE" && -z "$INSTALLED_EXE" ]]; then
  echo "missing --exe" >&2; usage 1
fi
case "$GFX" in auto|d3dmetal|dxvk|opengl) ;; *) die "--gfx must be auto, d3dmetal, dxvk or opengl";; esac
case "$FETCH" in ""|stable|devel|staging|gptk) ;; *) die "--fetch-wine must be stable, devel, staging or gptk";; esac
# Windows version: accept 10, win10, Windows 10...; Wine's registry names are winxp, win7, win8, win81, win10, win11
if [[ -n "$WINVER" ]]; then
  v="$(printf '%s' "$WINVER" | tr 'A-Z' 'a-z' | sed 's/^windows[ -]*//; s/^win//; s/\.//')"
  case "$v" in
    xp|7|8|81|10|11) WINVER="win$v" ;;
    *) die "--winver must be xp, 7, 8, 8.1, 10 or 11" ;;
  esac
  [[ "$WINVER" == win11 && "$FETCH" == gptk ]] && echo "warning: the GPTK runtime is old and may not know Windows 11" >&2
fi
[[ "$GFX" == d3dmetal && -z "$FETCH" && -z "$WINE" ]] && echo "warning: --gfx d3dmetal needs a Wine with D3DMetal; consider --fetch-wine gptk" >&2

if [[ -n "$SAVE_PROFILE" ]]; then
  {
    echo "# Profile generated by dmgexe.sh"
    for v in NAME DIR EXE WINE ICON FETCH GFX EMBED LINK INSTALL INSTALLED_EXE PREFIX_OVERRIDE WINVER TEMPLATES RETINA MSYNC ESYNC VSYNC WIN32 D3DC WINETRICKS; do
      printf '%s=%q\n' "$v" "${!v}"
    done
    printf 'ARGS=('; for a in "${ARGS[@]+"${ARGS[@]}"}"; do printf '%q ' "$a"; done; echo ')'
    printf 'ENVS=('; for a in "${ENVS[@]+"${ENVS[@]}"}"; do printf '%q ' "$a"; done; echo ')'
  } > "$SAVE_PROFILE"
  info "Profile saved to $SAVE_PROFILE"; exit 0
fi

# --- Resolve exe and folder -------------------------------------------------
# Where the launcher keeps the Windows prefix of an app (must match the launcher)

# --prefix-dir: absolute, and creatable now (a disconnected volume is reported here, not at launch)
if [[ -n "$PREFIX_OVERRIDE" ]]; then
  [[ "$PREFIX_OVERRIDE" == /* ]] || PREFIX_OVERRIDE="$PWD/$PREFIX_OVERRIDE"
  PREFIX_OVERRIDE="${PREFIX_OVERRIDE%/}"
  mkdir -p "$PREFIX_OVERRIDE" 2>/dev/null || die "cannot create the prefix folder $PREFIX_OVERRIDE (is the volume connected?)"
fi

# Turns a user-given path of a program installed in the prefix into "drive_c/..."
# Accepts C:\Program Files\App\app.exe, drive_c/..., "Program Files/App/app.exe" or the full path.
normalize_installed_exe() {
  local p pre="$PREFIX_DIR/"
  p="$(printf '%s' "$1" | tr '\\' '/')"
  case "$p" in
    "$pre"*)        p="${p#"$pre"}" ;;
    [A-Za-z]:/*)    [[ "${p:0:1}" == [Cc] ]] || die "only drive C: is supported in --installed-exe: $1"
                    p="drive_c/${p:3}" ;;
    drive_c/*)      ;;
    /*)             die "--installed-exe is outside the prefix ($PREFIX_DIR): $1" ;;
    *)              p="drive_c/$p" ;;
  esac
  case "/$p/" in */../*) die "--installed-exe must not contain '..': $1";; esac
  printf '%s' "$p"
}

PROGRAM_PREFIX_DIR=""
if [[ -n "$INSTALLED_EXE" && $INSTALL -eq 0 ]]; then
  # The program is already installed in the prefix of --name: nothing to copy, the app uses the prefix
  [[ -n "$NAME" ]] || die "--installed-exe needs --name (it names the prefix the program is installed in)"
  PREFIX_DIR="$(prefix_dir_of "$NAME")"
  INSTALLED_REL="$(normalize_installed_exe "$INSTALLED_EXE")"
  EXE_ABS="$PREFIX_DIR/$INSTALLED_REL"
  [[ -f "$EXE_ABS" ]] || die "not found in the prefix of '$NAME': $INSTALLED_REL (install it first with --install)"
  DIR="$(dirname "$EXE_ABS")"
  EXE_REL="$(basename "$EXE_ABS")"; EXE_REL_WIN="$EXE_REL"
  PROGRAM_PREFIX_DIR="$(dirname "$INSTALLED_REL")"
else
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
fi

[[ $RUN_NOW -eq 1 ]] && { OUT="$(mktemp -d)"; LINK=1; }
if [[ -z "$NAME" ]]; then
  NAME="$(basename "$EXE_ABS" .exe)"
  # an installer is usually called setup.exe / install.exe: the folder says more about the program
  if [[ $INSTALL -eq 1 ]] && printf '%s' "$NAME" | grep -qiE 'setup|install|instal'; then
    [[ "$(basename "$DIR")" != "/" ]] && NAME="$(basename "$DIR")"
  fi
fi
SLUG="$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"

# --- Installer mode ----------------------------------------------------------
# Runs the installer in the app's prefix, finds what it installed, then re-invokes this script to
# use the installed program. Each stage is a normal invocation of this script (DMGEXE_INSTALL_STAGE
# tells it which one), so every other option keeps working unchanged.

# every .exe of the prefix outside windows/, relative to the prefix
snapshot_exes() {
  [[ -d "$1/drive_c" ]] || return 0
  ( cd "$1" && find drive_c -path drive_c/windows -prune -o -type f -iname '*.exe' -print | LC_ALL=C sort )
}

# rank_new_exes PREFIX NAME < list: "score<TAB>path" lines, best first, without Wine's own programs,
# temp files, uninstallers, redistributables and helpers
rank_new_exes() {
  python3 -I -c '
import os, re, sys
prefix, name = sys.argv[1], sys.argv[2]
norm = lambda t: re.sub(r"[^a-z0-9]", "", t.lower())
skip_dirs = {"windows", "temp", "tmp", "internet explorer", "windows nt", "windows media player",
             "common files", "windowsapps"}
junk = [r"^unins", r"uninst", r"^remove", r"redist", r"^dxsetup", r"^dxwebsetup", r"^dotnet", r"^ndp",
        r"^setup", r"^install", r"^update", r"crash", r"helper$", r"^elevate", r"^createdump",
        r"subprocess", r"^cef", r"^vc_"]
rows = []
for line in sys.stdin:
    rel = line.rstrip("\n")
    if not rel: continue
    parts = rel.split("/")[1:]
    low = [x.lower() for x in parts]
    stem = os.path.splitext(parts[-1])[0]
    if any(d in skip_dirs for d in low[:-1]) or any(re.search(j, stem.lower()) for j in junk): continue
    score = 0
    if low[0].startswith("program files"): score += 40
    elif low[0] == "users" and "appdata" in low: score += 40 if "programs" in low else 10
    n = norm(stem)
    if len(parts) > 1 and n and n == norm(parts[-2]): score += 30
    if n and n == norm(name): score += 30
    elif len(n) >= 3 and norm(name) and (n in norm(name) or norm(name) in n): score += 15
    score -= 2 * (len(parts) - 1)
    try: score += min(10, os.path.getsize(os.path.join(prefix, rel)) >> 20)
    except OSError: pass
    rows.append((score, rel))
for score, rel in sorted(rows, key=lambda r: (-r[0], r[1])):
    print("%d\t%s" % (score, rel))
' "$1" "$2"
}

# args_without OPTION[:takes-value]...: ORIG_ARGS minus those options (used to build the stages)
args_without() {
  STAGE_ARGS=(); local i=0 a skip drop
  while [[ $i -lt ${#ORIG_ARGS[@]} ]]; do
    a="${ORIG_ARGS[$i]}"; drop=0
    for skip in "$@"; do
      case "$skip" in
        *:v) [[ "$a" == "${skip%:v}" ]] && { drop=1; i=$((i+1)); } ;;
        *)   [[ "$a" == "$skip" ]] && drop=1 ;;
      esac
    done
    i=$((i+1)); [[ $drop -eq 0 ]] && STAGE_ARGS+=("$a")
  done
  return 0
}

install_flow() {
  PREFIX_DIR="$(prefix_dir_of "$NAME")"
  local before after new rc=0 chosen="" line score rel n=0 i ans second
  local -a cands=() scores=()
  [[ -n "$INSTALLED_EXE" ]] && chosen="$(normalize_installed_exe "$INSTALLED_EXE")"
  before="$(mktemp)"; after="$(mktemp)"; new="$(mktemp)"
  snapshot_exes "$PREFIX_DIR" > "$before"

  info "Running the installer $(basename "$EXE_ABS") in the prefix of '$NAME'"
  args_without --install --installed-exe:v --arg:v --save-profile:v
  DMGEXE_INSTALL_STAGE=run bash "$SELF" ${STAGE_ARGS[@]+"${STAGE_ARGS[@]}"} -n "$NAME" --run --wait || rc=$?

  snapshot_exes "$PREFIX_DIR" > "$after"
  LC_ALL=C comm -13 "$before" "$after" > "$new"
  if [[ -z "$chosen" ]]; then
    while IFS=$'\t' read -r score rel; do cands+=("$rel"); scores+=("$score"); done < <(rank_new_exes "$PREFIX_DIR" "$NAME" < "$new")
  fi
  rm -f "$before" "$after" "$new"
  [[ $rc -ne 0 ]] && echo "warning: the installer ended with code $rc" >&2

  if [[ -z "$chosen" ]]; then
    n=${#cands[@]}
    if [[ $n -eq 0 ]]; then
      die "the installer did not leave any new program in the prefix (exit code $rc). If it installed somewhere else, use --installed-exe"
    elif [[ $n -eq 1 ]]; then
      chosen="${cands[0]}"
    elif [[ $(( ${scores[0]} - ${scores[1]} )) -ge 25 ]]; then
      chosen="${cands[0]}"
      for ((i=1; i<n; i++)); do echo "also found: ${cands[$i]}"; done
    elif [[ -t 0 && -t 1 ]]; then
      echo "The installer left several programs. Which one starts it?"
      for ((i=0; i<n; i++)); do echo "  $((i+1))) ${cands[$i]}"; done
      read -r -p "Number [1-$n]: " ans
      [[ "$ans" =~ ^[0-9]+$ && $ans -ge 1 && $ans -le $n ]] || die "invalid choice"
      chosen="${cands[$((ans-1))]}"
    else
      for ((i=0; i<n; i++)); do echo "candidate: ${cands[$i]}"; done
      echo "The installer finished, but it left several programs. Pick one and run again; the installer will not run again:" >&2
      echo "  dmgexe.sh -n \"$NAME\" --installed-exe \"<one of the candidates>\" [same options, without --install -e -d]" >&2
      exit 3
    fi
  fi
  [[ -f "$PREFIX_DIR/$chosen" ]] || die "not found in the prefix of '$NAME': $chosen"
  echo "installed-exe: $chosen"

  args_without --install --installed-exe:v --exe:v -e:v --dir:v -d:v
  DMGEXE_INSTALL_STAGE=generate exec bash "$SELF" ${STAGE_ARGS[@]+"${STAGE_ARGS[@]}"} -n "$NAME" --installed-exe "$chosen"
}
[[ $INSTALL -eq 1 ]] && install_flow

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

if [[ -n "$PROGRAM_PREFIX_DIR" ]]; then
  PROGRAM_REF=""
  info "The program lives in the prefix of '$NAME': nothing to copy"
elif [[ $LINK -eq 1 ]]; then
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
  echo "PROGRAM_PREFIX_DIR=$(q "$PROGRAM_PREFIX_DIR")"
  echo "PREFIX_OVERRIDE=$(q "$PREFIX_OVERRIDE")"
  echo "WINVER=$(q "$WINVER")"
  echo "TEMPLATES=$TEMPLATES"
  echo "TEMPLATE_ROOT=$(q "$CACHE/prefix-templates")"
  echo "WINE_REL=$(q "$WINE_REL")"
  echo "WINE_HINT=$(q "$WINE_BIN")"
  echo "RETINA=$RETINA MSYNC=$MSYNC ESYNC=$ESYNC VSYNC=$VSYNC WIN32=$WIN32"
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
# Where the Windows prefix is (same rules as prefix_dir_of in dmgexe.sh): an explicit --prefix-dir; else where
# this app already has it; else <folder chosen in Dmgexe's Storage>/<name>/prefix; else the default place.
CONFIG="$HOME/Library/Application Support/Dmgexe/config"
PREFIX_ROOT=""; [[ -f "$CONFIG" ]] && PREFIX_ROOT="$(sed -n 's/^prefix_root=//p' "$CONFIG" | head -1)"
REC=""; [[ -f "$SUPPORT/.prefix-path" ]] && REC="$(cat "$SUPPORT/.prefix-path")"
volume_missing() { case "$1" in /Volumes/*) [[ -d "/Volumes/$(echo "${1#/Volumes/}" | cut -d/ -f1)" ]] && return 1 || return 0;; esac; return 1; }
fatal_prefix() {
  osascript -e "display dialog \"$1\" with title \"$APP_NAME\" buttons {\"OK\"} default button 1 with icon stop" >/dev/null 2>&1
  echo "$1"; exit 1
}
if [[ -n "$PREFIX_OVERRIDE" ]]; then PREFIX="$PREFIX_OVERRIDE"
elif [[ -n "$REC" && -d "$REC" ]]; then PREFIX="$REC"
elif [[ -z "$REC" && -f "$SUPPORT/prefix/system.reg" ]]; then PREFIX="$SUPPORT/prefix"   # made before the location was recorded
elif [[ -n "$REC" ]] && volume_missing "$REC"; then
  fatal_prefix "This program's Windows environment is on a drive that is not connected: $REC. Connect it and try again."
elif [[ -n "$PREFIX_ROOT" ]]; then PREFIX="$PREFIX_ROOT/$APP_NAME/prefix"
else PREFIX="$SUPPORT/prefix"; fi
if [[ "$PREFIX" != "$SUPPORT/prefix" ]] && ! mkdir -p "$PREFIX" 2>/dev/null; then
  fatal_prefix "Cannot use the folder for this program's Windows environment: $PREFIX. Is the external drive connected?"
fi
if [[ -n "$PREFIX_OVERRIDE" ]]; then touch "$SUPPORT/.prefix-pinned"; else rm -f "$SUPPORT/.prefix-pinned"; fi
echo "$PREFIX" > "$SUPPORT/.prefix-path"   # lets Dmgexe's Storage list find prefixes kept elsewhere
if [[ -n "${DMGEXE_FOREGROUND:-}" ]]; then exec > >(tee -a "$LOG") 2>&1; else exec >>"$LOG" 2>&1; fi
echo "=== $(date) ==="

alert() { osascript -e "display dialog \"$1\" with title \"$APP_NAME\" buttons {\"OK\"} default button 1 with icon stop" >/dev/null 2>&1; }

# Program
if [[ -n "$PROGRAM_PREFIX_DIR" ]]; then PROGRAM_DIR="$PREFIX/$PROGRAM_PREFIX_DIR"   # installed inside the prefix
elif [[ -n "$PROGRAM_REF" ]]; then PROGRAM_DIR="$PROGRAM_REF"
else PROGRAM_DIR="$RES/program"; fi
if [[ ! -f "$PROGRAM_DIR/$EXE_REL" ]]; then
  if [[ -n "$PROGRAM_PREFIX_DIR" ]]; then alert "Cannot find the program at: $PROGRAM_DIR. It is installed inside this app's Windows prefix, which is missing or was reset. Install it again with Dmgexe."
  else alert "Cannot find the program at: $PROGRAM_DIR"; fi
  exit 1
fi

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

export WINEPREFIX="$PREFIX"
export WINEDEBUG="${WINEDEBUG:--all}"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-winemenubuilder.exe=d}"
[[ $WIN32 -eq 1 ]] && export WINEARCH=win32
[[ $MSYNC -eq 1 ]] && export WINEMSYNC=1
[[ $ESYNC -eq 1 ]] && export WINEESYNC=1
export MTL_HUD_ENABLED="${MTL_HUD_ENABLED:-0}"
export MVK_CONFIG_LOG_LEVEL="${MVK_CONFIG_LOG_LEVEL:-1}"   # MoltenVK prints ~150 lines per Vulkan instance otherwise (errors only)
for kv in "${EXTRA_ENV[@]}"; do export "$kv"; done

# Prefix templates: a prefix built with this runtime and this list of winetricks components is kept in
# TEMPLATE_ROOT and cloned for every other app that asks for the same (APFS clone: no extra space).
TKEY=""; TDIR=""; FRESH=0
if [[ $TEMPLATES -eq 1 && -n "$WINETRICKS" && ! -f "$SUPPORT/.winetricks-done" ]] && command -v shasum >/dev/null 2>&1; then
  RUNTIME_ID="$("${RUN[@]}" "$WINE" --version 2>/dev/null)"
  TKEY="$({ echo "$RUNTIME_ID"; shasum -a 256 "$WINE" | cut -d' ' -f1; echo "$WIN32 $(uname -m)"
            # shellcheck disable=SC2086
            printf '%s\n' $WINETRICKS | sort -u; } | shasum -a 256 | cut -c1-16)"
  TDIR="$TEMPLATE_ROOT/$TKEY"
fi

# copy a prefix: a clone when both are on the same APFS volume, else a plain copy
clone_prefix() { mkdir -p "$2" && { cp -cRp "$1/." "$2/" 2>/dev/null || cp -Rp "$1/." "$2/"; }; }

# First launch: create the prefix
if [[ ! -f "$WINEPREFIX/system.reg" ]]; then
  # nothing is set up in a new prefix, whatever the markers of an earlier one say
  rm -f "$SUPPORT"/.winetricks-done "$SUPPORT"/.d3dcompiler-done "$SUPPORT"/.dxvk-done "$SUPPORT"/.opengl-done \
        "$SUPPORT"/.retina-* "$SUPPORT"/.winver-*
  if [[ -n "$TKEY" && -f "$TDIR/.ok" ]] && clone_prefix "$TDIR/prefix" "$WINEPREFIX" && [[ -f "$WINEPREFIX/system.reg" ]]; then
    echo "creating prefix at $WINEPREFIX from the saved template $TKEY ($WINETRICKS)"
    osascript -e "display notification \"Preparing the Windows environment from a saved template…\" with title \"$APP_NAME\"" >/dev/null 2>&1
    touch "$SUPPORT/.winetricks-done"
  else
    echo "creating prefix at $WINEPREFIX with $WINE"
    osascript -e "display notification \"Preparing the Windows environment (first launch only)…\" with title \"$APP_NAME\"" >/dev/null 2>&1
    "${RUN[@]}" "$WINE" wineboot --init || { alert "Prefix creation failed. Check: $LOG"; exit 1; }
    "${RUN[@]}" "$(dirname "$WINE")/wineserver" -w 2>/dev/null
    FRESH=1
  fi
fi

# Optional winetricks (once). It runs first, on the plain prefix: with DXVK already installed every
# Wine process an installer starts would also start Vulkan (slow, and it floods the log). Some verbs
# (dotnet) change the Windows version themselves, so the version below is applied after them.
if [[ -n "$WINETRICKS" && ! -f "$SUPPORT/.winetricks-done" ]]; then
  WT="$(command -v winetricks || true)"
  if [[ -n "$WT" ]]; then
    echo "installing winetricks components: $WINETRICKS (first launch only; this can take many minutes, .NET the longest)"
    osascript -e "display notification \"Installing dependencies ($WINETRICKS)… this can take a while\" with title \"$APP_NAME\"" >/dev/null 2>&1
    # shellcheck disable=SC2086
    if "${RUN[@]}" "$WT" -q $WINETRICKS; then
      touch "$SUPPORT/.winetricks-done"
      # keep this clean prefix as a template for the next app that asks for the same components
      if [[ $FRESH -eq 1 && -n "$TKEY" && ! -f "$TDIR/.ok" ]]; then
        "${RUN[@]}" "$(dirname "$WINE")/wineserver" -w 2>/dev/null
        TMP_T="$TDIR.tmp.$$"; rm -rf "$TMP_T"
        if mkdir -p "$TMP_T" && clone_prefix "$WINEPREFIX" "$TMP_T/prefix"; then
          printf '%s\t%s\t%s\n' "$(echo $WINETRICKS | tr ' ' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')" "$RUNTIME_ID" "$(date +%Y-%m-%d)" > "$TMP_T/info"
          touch "$TMP_T/.ok"; rm -rf "$TDIR"; mv "$TMP_T" "$TDIR" && echo "saved prefix template $TKEY"
        else rm -rf "$TMP_T"; fi
      fi
    fi
  else
    echo "winetricks is not installed; skipping ($WINETRICKS)"
  fi
fi

# Retina
if [[ ! -f "$SUPPORT/.retina-$RETINA" ]]; then
  v=n; [[ $RETINA -eq 1 ]] && v=y
  "${RUN[@]}" "$WINE" reg add 'HKCU\Software\Wine\Mac Driver' /v RetinaMode /t REG_SZ /d "$v" /f
  rm -f "$SUPPORT"/.retina-*; touch "$SUPPORT/.retina-$RETINA"
fi

# Windows version reported to the program (HKCU\Software\Wine\Version); empty = the runtime's default
if [[ ! -f "$SUPPORT/.winver-$WINVER" && ( -n "$WINVER" || -n "$(ls "$SUPPORT"/.winver-* 2>/dev/null)" ) ]]; then
  if [[ -n "$WINVER" ]]; then "${RUN[@]}" "$WINE" reg add 'HKCU\Software\Wine' /v Version /t REG_SZ /d "$WINVER" /f
  else "${RUN[@]}" "$WINE" reg delete 'HKCU\Software\Wine' /v Version /f; fi
  rm -f "$SUPPORT"/.winver-*; [[ -n "$WINVER" ]] && touch "$SUPPORT/.winver-$WINVER"
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
  # DXVK talks to Metal through MoltenVK: use the one bundled with the runtime, else a system one
  if [[ ! -f "$(dirname "$WINE")/../lib/wine/x86_64-unix/winevulkan.so" || "$WINE" == *"Game Porting Toolkit"* ]]; then
    echo "This runtime has no Vulkan support, so DXVK cannot work with it. Use Wine Devel, Staging or Stable."
    alert "DXVK does not work with this runtime (Game Porting Toolkit has no Vulkan). Choose Wine Devel, Staging or Stable as the runtime, or use D3DMetal."
    exit 1
  fi
  MVK_DIR=""
  for d in "$(dirname "$WINE")/../lib" /opt/homebrew/lib /usr/local/lib; do
    [[ -f "$d/libMoltenVK.dylib" ]] && { MVK_DIR="$(cd "$d" && pwd -P)"; break; }
  done
  if [[ -n "$MVK_DIR" ]]; then
    export DYLD_FALLBACK_LIBRARY_PATH="$MVK_DIR:${DYLD_FALLBACK_LIBRARY_PATH:-$HOME/lib:/usr/local/lib:/usr/lib}"
  else
    echo "MoltenVK not found: DXVK cannot work without it (install it with: brew install molten-vk)"
    alert "DXVK needs MoltenVK, which is not installed. Install it with: brew install molten-vk (or open Dmgexe and use the Install MoltenVK button)."
    exit 1
  fi
  [[ $VSYNC -eq 0 ]] && export DXVK_CONFIG="${DXVK_CONFIG:+$DXVK_CONFIG; }d3d9.presentInterval = 0; dxgi.syncInterval = 0"
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
      ( export WINEPREFIX="$(prefix_dir_of "$NAME")"
        arch -x86_64 "$ws" -k || "$ws" -k ) 2>/dev/null
    fi
  }
  DMGEXE_FOREGROUND=1 "$APP/Contents/MacOS/launcher" & CH=$!
  trap stop_program TERM INT
  rc=0; wait "$CH" || rc=$?
  trap - TERM INT
  wait "$CH" 2>/dev/null || true
  if [[ $WAIT_ALL -eq 1 && -n "$WINE_BIN" && -x "$(dirname "$WINE_BIN")/wineserver" ]]; then
    # installers often hand over to a second process: wait until the prefix is idle
    ( export WINEPREFIX="$(prefix_dir_of "$NAME")"
      if [[ "$(uname -m)" == "arm64" ]] && file -b "$WINE_BIN" | grep -q x86_64; then arch -x86_64 "$(dirname "$WINE_BIN")/wineserver" -w
      else "$(dirname "$WINE_BIN")/wineserver" -w; fi ) 2>/dev/null || true
  fi
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
