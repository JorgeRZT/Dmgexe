<p align="center"><img src="gui/icon.svg" width="128" alt="Dmgexe icon"></p>

# Dmgexe

[![Release](https://img.shields.io/github/v/release/JorgeRZT/Dmgexe?style=flat-square)](https://github.com/JorgeRZT/Dmgexe/releases/latest)
[![License: MIT](https://img.shields.io/github/license/JorgeRZT/Dmgexe?style=flat-square)](LICENSE.md)
![Platform: macOS](https://img.shields.io/badge/platform-macOS%2013%2B-blue?style=flat-square&logo=apple&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-supported-brightgreen?style=flat-square)
![Swift 5](https://img.shields.io/badge/Swift-5-orange?style=flat-square&logo=swift&logoColor=white)
![Shell: bash](https://img.shields.io/badge/shell-bash-4eaa25?style=flat-square&logo=gnubash&logoColor=white)
[![Last commit](https://img.shields.io/github/last-commit/JorgeRZT/Dmgexe?style=flat-square)](https://github.com/JorgeRZT/Dmgexe/commits/main)
[![Stars](https://img.shields.io/github/stars/JorgeRZT/Dmgexe?style=flat-square)](https://github.com/JorgeRZT/Dmgexe/stargazers)

Package a Windows program as a double-clickable macOS `.app`.

Dmgexe does **not** translate Windows code into native macOS code, which is not
possible without the source. It wraps the program in an `.app` that runs it
through a compatibility runtime, optionally with a different graphics backend
(see [Credits](#credits) for the components involved). To the user it looks like
a normal Mac app: icon, Dock, double-click.

It comes in two parts:

- `dmgexe.sh`: the command-line tool that does the work.
- `Dmgexe.app`: a small SwiftUI window around it, with a library of saved
  programs.

## Requirements

- A Mac, ideally Apple Silicon (macOS 13 or later for the GUI).
- On Apple Silicon, the x86_64 translation layer (Rosetta 2) must be installed.
- Xcode command-line tools (`swiftc`) to build the GUI.
- Internet access when using `--fetch-wine`, `--gfx dxvk` or `--gfx opengl`.
- Optional: [winetricks](https://github.com/Winetricks/winetricks) (`brew install winetricks`) for
  `--winetricks` components, and MoltenVK (`brew install molten-vk`, or the **Install MoltenVK**
  button) for `--gfx dxvk` with a runtime that does not bundle it.
- Everything else (`python3`, `rsync`, `sips`, `iconutil`, `codesign`, `lsof`, `ps`) ships with macOS.

## Quick start

### GUI

```bash
gui/build.sh          # creates Dmgexe.app in the project root
open Dmgexe.app
```

Choose the `.exe`, check the program folder, pick a runtime source and press
**Generate .app**. The log shows progress and, when finished, buttons to reveal
or open the result.

The settings form has two tabs: **Generate app** creates a `.app`, and **Run program**
launches the program right away without creating anything (it can be stopped
with the **Stop** button). Both tabs share the same settings and the same
prefix, so a program set up in one behaves the same in the other.

The main window is a **library** shown as a grid of cards. Press **Add program**
to open the settings form, fill it in and press **Save to library** to store the
current form (executable, folder, runtime source, graphics backend, arguments,
variables…) as a card.

- **Click a card** to launch the program straight away (a spinner shows while it
  runs, and **Stop** appears at the top).
- **Right-click a card** for **Run**, **Settings…** (reopens the form to edit it),
  **Cover** and **Delete**.
- The toggle at the top switches the grid between **vertical** (2:3) and
  **horizontal** (16:9) cards. The choice is remembered.

The library is stored in `~/Library/Application Support/Dmgexe/library.json`.

#### Covers

Each program can have a vertical and a horizontal cover, set independently from
local image files: right-click → **Cover** → **Set vertical / horizontal cover…**,
or click the small thumbnails at the top of the settings form. Images are copied
to `~/Library/Application Support/Dmgexe/covers/`. A card only shows the cover of
the current style; without one it shows a placeholder with the program's name.
Replacing or removing a cover (or deleting the program) deletes the copied file.

#### Detection and suggestions

When an executable is chosen, the form inspects it (without running it) and the
DLLs next to it, and shows under **Graphics**:

- the **architecture** (32 or 64-bit, from the PE header);
- the **graphics APIs it can use** (OpenGL, DirectX 9, 10/11, 12, Vulkan), found
  from the names of the graphics DLLs it links or loads;
- a **Suggested** line with an **Apply** button that proposes the runtime, the
  graphics backend and the winetricks verbs it seems to need: GPTK for DirectX
  11/12, a regular Wine with DXVK for DirectX 9, and verbs such as `vcrun2022`
  or `d3dx9` for the redistributables it links but does not ship. `dotnet48` is
  only suggested for a program that really is a .NET assembly (it is a slow
  install, and many native programs mention `mscoree.dll` without needing it).
  Apply only fills the form; it never overrides a runtime or backend that looks
  like a deliberate choice, and nothing changes until you press it.

This is a static guess: it says what a program can use, not what it ends up
using, and it cannot see inside packed executables. Having OpenGL in the list does
not mean the OpenGL backend is needed: programs that use OpenGL run with the
other backends through the Mac's own (hardware) OpenGL. The OpenGL backend is CPU
software rendering and shows a warning.

The app is ad-hoc signed only. If macOS blocks it, right-click it and choose
**Open**.

### Programs that are not installed yet (`setup.exe`)

Dmgexe normally wraps a program that already runs from a folder. A program that
ships as an installer needs one more step, and there is a mode for it. In the form,
tick **This is an installer (setup.exe)**, choose the setup file and press
**Install & generate .app** (or **Install & run** in the other tab):

1. The installer runs inside the app's own Windows prefix, with the runtime, graphics
   backend, Windows version, variables and winetricks verbs of the form. Use a proper
   **App name**: it names the prefix (for a file called `setup.exe` the folder name is proposed).
2. Dmgexe waits for every process the installer started, compares the prefix before
   and after, and looks for the program that was installed. Wine's own programs,
   temporary files, uninstallers, redistributables and crash handlers are ignored.
3. If one program clearly stands out (it is in `Program Files`, is named like the
   folder or the app...), it is used. Otherwise a window asks which one starts it;
   the installer is **not** run again.
4. The `.app` points to the installed program inside the prefix. Nothing is copied
   into the app. The library card remembers the installed program, so clicking it
   launches it directly. **Install again** forgets it and runs the installer again.

Because the program lives in its prefix, an app made this way only works on the Mac
where it was installed.

### Where the Windows prefix lives

The prefix (the installed program, its saved games, Wine's own files, hundreds of MB
at least) is the part that takes space on the Mac. By default it is
`~/Library/Application Support/<App name>/prefix`. You can move it to another drive in two ways:

- **For every program**: in **Storage → Where new prefixes are created** choose a folder, for
  example `/Volumes/Disk/Bottles`. New prefixes are created in `<folder>/<App name>/prefix`;
  prefixes that already exist stay where they are until you press **Move to folder** on them.
- **For one program**: fill **Install location** in its form (or pass `--prefix-dir`). That
  program keeps its own place whatever the global folder says, and it cannot be changed after
  installing.

Either way the drive must be connected whenever the program runs: the app says so if it is not,
and it never starts a new empty prefix in its place. It also works for ordinary programs, not
only for installers. Only small files (the log, a few markers) stay on the Mac.

### Windows version

The **Windows version** selector (`--winver`) sets the version Wine reports to the program,
like the Windows version of a CrossOver bottle. Use it for a program that refuses to start
(or misbehaves) unless it sees Windows XP or 7, or one that needs 10. It is written into the
prefix once, before anything runs (installers included), and changing it later rewrites it;
"Runtime default" removes it again. It does not install another Windows: the API underneath is
Wine's. Windows 11 needs a recent runtime (the GPTK one is old and may not know it), and a real
32-bit XP prefix is not available because current Wine builds for Mac are 64-bit only.

### Storage

The **Storage** button of the library (it turns orange and shows a count while Wine processes are
running) opens a window with:

- **Running now**: the Wine processes alive at this moment, grouped by program, each with a
  **Stop** button, plus **Stop all**. A closed program often leaves Wine's own services
  (`services.exe`, `winedevice.exe`...) behind; they keep the prefix busy, so it cannot be deleted
  or moved until they are stopped. Stopping asks the prefix's wineserver to close everything,
  then terminates and finally kills what is left. A process belongs to a program when its working
  directory or an open file is inside the prefix (or inside its wineserver's folder).
- **Where new prefixes are created**: one folder for every program (for example on an external
  drive), instead of `~/Library/Application Support`. It applies to everything made or run
  afterwards, installers included. A prefix that already exists stays where it is until you press
  **Move to folder** on it (a copy first when the drive is different; nothing is lost if it fails).
  A program with its own **Install location** keeps that one. If a prefix is on a drive that is not
  connected the app says so; it never starts a new empty prefix in its place.
- every **Windows prefix** (one per program, including those kept on another drive) with its size,
  the winetricks components installed in it, whether a library program uses it, and whether the
  library asks for components that are missing. **Delete…** removes the prefix after asking, and is
  refused while a program runs in it. The program builds a new one at its next launch (in the
  folder set above). A program installed from a `setup.exe` lives in its prefix, so deleting it means
  installing again.
- the **prefix templates** (see above), with their components, runtime and size.
- the **winetricks downloads** (installers cached by winetricks), per component, with a button
  to delete one or all. This frees space and does not affect the components already installed.

Individual winetricks components cannot be uninstalled: winetricks installs them into the
prefix and has no general way to remove them, so the only way to drop one is a new prefix.
The chosen folder is saved in `~/Library/Application Support/Dmgexe/config` (`prefix_root=…`),
which the generated apps read when they start. Everything the window does is also available
from the command line: `--list-wine`, `--stop-wine
NAME|all|pid:N`, `--get-prefix-root`, `--set-prefix-root DIR|default`, `--move-prefix NAME`,
`--list-prefixes`, `--delete-prefix NAME`, `--list-templates`, `--delete-template KEY|all`,
`--list-cache`, `--delete-cache VERB|all`.

### Prefix templates

Installing winetricks components is slow, so Dmgexe does it once per combination. The first
prefix built with a given runtime and list of components (`dotnet48`, `vcrun2022`…, in any
order) is kept as a **template** in `~/Library/Caches/dmgexe/prefix-templates`, and every later
app asking for the same starts from a copy of it: no winetricks, no `wineboot`, seconds instead
of minutes. On the same APFS drive the copy is a clone, which takes no extra space until
something changes; on another drive (for example `--prefix-dir` on an external disk) it is a
real copy, still much faster than installing.

- The template is taken right after winetricks, before the program or an installer touches the
  prefix, so it never contains a program or its saved games. The Windows version, Retina,
  graphics backend and the program itself are applied to each app separately.
- A template is only used for the same runtime (Wine version and build) and the same
  components. A different runtime, 32-bit prefix or component list builds its own.
- Nothing is saved if winetricks fails, or if the prefix already existed.
- `--no-template` turns it off. **Storage** lists the templates and deletes them; deleting one
  does not affect prefixes made from it. Components added later to an existing prefix are
  installed in place, as before.

### Slow first launch

The first launch of an app with winetricks components installs them, and that can take a long
time: `dotnet40`/`dotnet48` run Microsoft's installers under Wine and take the longest (10–30
minutes, and they often do not work on a 64-bit prefix), `vcrun*` and `d3dx*` take seconds. Only
ask for what the program needs; most native games do not need .NET. The components are installed
on the plain prefix before the graphics backend is set up (so DXVK does not slow every process
the installers start), and the chosen Windows version is applied afterwards. If you stop the
launch in the middle, the next one starts the installation again: delete the half-built prefix
in **Storage** first.

### Command line

```bash
./dmgexe.sh -e bin/program.exe -d /path/to/ProgramFolder -n "My Program" \
            --fetch-wine gptk --gfx d3dmetal -o ~/Desktop
```

`-e` may be absolute or relative to `-d`, and must be inside it.

For an installer:

```bash
# run setup.exe in the prefix of "My Program", detect what it installed, make the app
./dmgexe.sh --install -e ~/Downloads/MyProgram/setup.exe -n "My Program" \
            --fetch-wine devel -o ~/Desktop
```

When the installer leaves several candidates (and the terminal is not interactive)
the command lists them as `candidate: drive_c/...` lines and exits with code 3.
The installation is kept; choose one and run again without the installer:

```bash
./dmgexe.sh -n "My Program" --installed-exe "C:\Program Files\My Program\program.exe" \
            --fetch-wine devel -o ~/Desktop
```

## Options

| Option | Description |
| --- | --- |
| `-e, --exe PATH` | Startup executable. Required. |
| `-d, --dir PATH` | Program folder. Defaults to the exe's folder. |
| `-n, --name NAME` | App name. Defaults to the exe's name. |
| `-o, --out DIR` | Output folder. Defaults to the current directory. |
| `-w, --wine PATH` | Runtime binary or the folder of a runtime installation. Auto-detected if omitted. |
| `-i, --icon FILE` | `.icns`, `.png` or `.ico`. Extracted from the exe by default. |
| `--embed-wine` | Copy the runtime into the app (self-contained, larger). |
| `--fetch-wine K` | Download and cache a runtime build and embed it: `stable`, `devel`, `staging` or `gptk`. |
| `--gfx G` | Graphics backend: `auto` (default), `d3dmetal` (DX11/12, use with `gptk`), `dxvk` (DX9/10/11) or `opengl` (OpenGL 4.6 compatibility profile, rendered in software: slow). |
| `--install` | `-e` is an installer. Run it in the prefix of `--name`, detect the installed program and build the app (or `--run` it) from that. Exit code 3 if the program must be chosen. |
| `--installed-exe PATH` | Program already installed in the prefix of `--name` (`C:\...`, `Program Files/...` or `drive_c/...`). `-e` and `-d` are not needed; nothing is copied. |
| `--winver V` | Windows version Wine reports to the program: `xp`, `7`, `8`, `8.1`, `10` or `11` (default: the runtime's own). Also applied before an installer runs. |
| `--prefix-dir DIR` | Keep the Windows prefix in `DIR` instead of `~/Library/Application Support/<Name>/prefix` (e.g. on an external volume). Repeat it with `--installed-exe` if you use it with `--install`. |
| `--list-wine` / `--stop-wine T` | Print the Wine processes running now (with the program they belong to) / stop those of program `T`, of every program (`all`) or one (`pid:N`). |
| `--get-prefix-root` / `--set-prefix-root DIR` | Print / set the folder where new prefixes are created for every program (`default` resets it). |
| `--move-prefix NAME` | Move the prefix of `NAME` to that folder. |
| `--list-prefixes` / `--list-cache` | Print the Windows prefixes / winetricks downloads and their sizes (tab separated), then exit. |
| `--delete-prefix NAME` / `--delete-cache VERB` | Delete the prefix of app `NAME` / the cached downloads of a verb (`all` for every one), then exit. |
| `--no-template` | Do not reuse or save prefix templates. |
| `--list-templates` / `--delete-template KEY` | Print the prefix templates / delete one (`all` for every one), then exit. |
| `--wait` | With `--run`, also wait for every process the program started (used by `--install`). |
| `--run` | Do not keep an app: run the program right away (output is streamed) and clean up when it exits. |
| `--link` | Do not copy the program into the app; point to the original folder. |
| `--arg ARG` | Argument for the exe (repeatable). |
| `--env K=V` | Extra environment variable (repeatable). |
| `--winetricks "verbs"` | Install winetricks verbs on first launch (needs `winetricks` installed). |
| `--no-d3dcompiler` | Skip the native `d3dcompiler_47` (see below). |
| `--retina` | Enable Retina mode (sharper, slower). |
| `--no-msync` | Disable MSYNC. |
| `--no-esync` | Disable ESYNC. |
| `--no-vsync` | Disable VSync (DXVK backend only). |
| `--win32` | 32-bit prefix (old runtimes only). |
| `--profile FILE` / `--save-profile FILE` | Load / save settings (see below). |

### Profiles

A profile is a plain bash file. Keep one per program and regenerate the app with
a single command; command-line options override the profile.

```bash
./dmgexe.sh -e bin/program.exe -d ProgramFolder --fetch-wine gptk --gfx d3dmetal \
            --save-profile program.profile
./dmgexe.sh --profile program.profile -o ~/Desktop
```

```bash
# program.profile (every variable is optional; paths are relative to the profile)
NAME="My Program"; DIR="./ProgramFolder"; EXE="bin/program.exe"
FETCH=gptk; GFX=d3dmetal
ARGS=(--windowed); ENVS=(WINEDEBUG=-all); WINETRICKS="vcrun2022"
WINVER=win7; PREFIX_OVERRIDE="/Volumes/Disk/Games/MyProgram/prefix"; TEMPLATES=1
# for an installer: INSTALL=1 (EXE is then the setup program), or INSTALLED_EXE="drive_c/Program Files/..."
```

## Tests

```bash
tests/run.sh              # the whole suite (a few minutes)
tests/run.sh install      # only the tests whose name contains "install"
tests/run.sh --gui        # also compile the SwiftUI front-end
```

The tests that deal with running processes use copies of `sleep` named like Wine's programs, and
`DMGEXE_PROCESS_ROOT` (set by the test-suite) limits the process search to the test's own folder,
so the suite can never see or stop the Wine programs you are really running.

The tests use a fake Wine (`tests/fixtures`) that records what it is asked to run and
can simulate an installer, so they need no Wine, no network and never touch your
real `~/Library`: every test gets its own `HOME`. The SwiftUI code is only compiled,
there are no UI tests.

## How the generated app works

```
My Program.app/Contents/
├── MacOS/launcher        bash launcher
├── Resources/
│   ├── program/          your program (omitted with --link)
│   ├── runtime/          embedded runtime (with --fetch-wine / --embed-wine)
│   ├── dxvk/             with --gfx dxvk
│   ├── mesa/             with --gfx opengl
│   ├── d3dcompiler/      native d3dcompiler_47 (32 and 64 bit)
│   └── AppIcon.icns
└── Info.plist
```

On first launch the launcher, in this order:

1. finds the prefix (see [Where the Windows prefix lives](#where-the-windows-prefix-lives))
   and creates it, from a [template](#prefix-templates) when one matches;
2. applies the winetricks verbs, on the plain prefix;
3. sets Retina and the Windows version;
4. installs the native `d3dcompiler_47` and the selected graphics backend;
5. runs the exe from its own folder (or the installed program, from the prefix).

Everything the launcher does is logged to `~/Library/Application Support/<Name>/launcher.log`;
that file is the first place to look when something fails. The same folder holds small markers
(`.winetricks-done`, `.retina-*`, `.winver-*`, `.prefix-path`...) that remember what was already
set up. Switching an app from `--gfx opengl` to another backend restores the original files in
its prefix.

### Files and folders

| Where | What |
| --- | --- |
| `~/Library/Application Support/Dmgexe/` | `library.json` (the library), `covers/`, `config` (folder for new prefixes) |
| `~/Library/Application Support/<Name>/` | `launcher.log`, setup markers, and the `prefix/` unless it was put elsewhere |
| `~/Library/Caches/dmgexe/` | downloaded runtimes, DXVK, Mesa and `d3dcompiler_47`; `prefix-templates/` (override with `DMGEXE_CACHE`) |
| `~/.cache/winetricks/` or `~/Library/Caches/winetricks/` | what winetricks downloaded (see Storage) |

### Why `d3dcompiler_47`?

The shader compiler that ships with the runtime cannot compile the HLSL shaders
of many DX11 programs (typically reported as `Failed to compile shader ... syntax
error`). The generated apps therefore install Microsoft's native DLL, downloaded
from the same source and checked against the same SHA-256 hashes that winetricks
uses. Disable this with `--no-d3dcompiler`.

## Troubleshooting

Check `~/Library/Application Support/<Name>/launcher.log` first (the **Run
program** tab streams the same output).

- **`Failed to lookup symbol: UnmapViewOfFile2`** or **`... requires Windows
  version 1803 or later`**: the `gptk` runtime is old. Use a newer one with
  `--fetch-wine devel` (or `staging` / `stable`).
- **`Failed to create OpenGL context`**: the program asks for an OpenGL version
  that macOS does not provide (macOS offers OpenGL 2.1 in the compatibility
  profile and 4.1 only in the core profile). Use `--gfx opengl`, which renders
  OpenGL 4.6 in software. It works, but it is much slower than hardware
  rendering.
- **`Failed to compile shader ... syntax error`**: make sure the native
  `d3dcompiler_47` is installed (the default; do not pass `--no-d3dcompiler`).
- **`Required Vulkan extension VK_KHR_surface not supported` / `Failed to create
  DXGI Factory`** with `--gfx dxvk`: the `gptk` runtime has no Vulkan support, so
  DXVK cannot work with it. Use `--fetch-wine devel` (or `stable` / `staging`),
  which bundle MoltenVK. If MoltenVK is not found, install it with
  `brew install molten-vk` (the GUI offers an **Install MoltenVK** button).
- **`VK_QUERY_TYPE_PIPELINE_STATISTICS is not supported`** (crash) with
  `--gfx dxvk`: MoltenVK does not implement pipeline-statistics queries and the
  bundled DXVK build requires them for some programs. Use `--gfx d3dmetal`.
- **Black screen in one level or scene** while the menu, sound and input work:
  usually a rendering feature the graphics backend does not support. Try lowering
  the program's graphics options (for example light occlusion), or another
  `--gfx` backend.
- **Slow loading with a program on an external drive**: with `--link` every file
  is read from the original folder. Copy the program to the internal disk or
  generate the app without `--link`.
- **Choosing a runtime**: `gptk` is the best option for Direct3D 11/12; a recent
  `devel` runtime is better for everything else.
- **A winetricks verb was added but nothing was installed**: verbs are installed
  once per prefix. Delete the prefix in **Storage** (or use another app name) to
  install a changed list.
- **The first launch takes very long**: see [Slow first launch](#slow-first-launch). It is
  almost always `dotnet40`/`dotnet48`.
- **A DirectX 9 game shows a black screen (the cursor is visible)** with the `gptk` runtime:
  D3DMetal only translates DirectX 11/12. Use a `staging` or `devel` runtime with
  `--gfx dxvk`, and try Windows 7 as the Windows version.
- **Storage will not delete or move a prefix ("in use")**: Wine processes are still alive in it
  (a closed program often leaves `services.exe` and `winedevice.exe` behind). Stop them in
  **Storage → Running now** (or `--stop-wine NAME`) and try again.
- **"…drive that is not connected"**: the prefix lives on an external drive that is not mounted.
  Connect it; nothing was lost.

## Limitations

- Compatibility depends on each program. Some run well, some are slow or do not
  start at all.
- DirectX 12 and very recent software are the hardest.
- Kernel-level anti-cheat generally does not work.
- Some DRM and launchers cause trouble.
- `--gfx opengl` is software rendering and is slow by nature; `--gfx dxvk` uses
  an old build (1.10.3), needs a non-`gptk` runtime, and fails on programs that
  require pipeline-statistics queries, which MoltenVK does not support.
- `--no-vsync` only takes effect with `--gfx dxvk`; with D3DMetal use the
  program's own settings.
- The detection in the GUI is a heuristic (see above) and winetricks verbs such as
  `dotnet48` are not guaranteed to install on every runtime.
- A native macOS build of a program, when it exists, will almost always perform
  better than any compatibility layer.
- The installer mode finds the installed program by looking for new `.exe` files; it
  does not read shortcuts, so it may need your choice, and an installer that puts its
  files outside `C:` or only registers a service is not handled.
- An installer that needs a reboot, or asks for something the fake Windows cannot give,
  may fail like it would on a real PC; check the log.
- Apps made from an installer depend on their prefix and cannot be moved to another Mac.
- Prefix templates are only reused for the same runtime build and the same list of components,
  and they have only been exercised with a stand-in Wine in the tests: if an app behaves oddly
  right after being cloned, run it with `--no-template`.
- The processes shown by **Running now** are those whose working directory or open files are in a
  known prefix; a Wine process that has neither is listed as "(unknown)" and can only be stopped
  one by one.
- Apps with an embedded runtime are not signed; if macOS blocks one, run
  `xattr -cr "My Program.app"`.

## Credits

Dmgexe is glue code. The heavy lifting is done by these projects, which it
downloads, bundles or relies on:

- [Wine](https://www.winehq.org/): the Windows compatibility layer that runs the programs.
- [Gcenx's macOS Wine builds](https://github.com/Gcenx/macOS_Wine_builds) and
  [Game Porting Toolkit builds](https://github.com/Gcenx/game-porting-toolkit):
  the prebuilt runtime packages fetched by `--fetch-wine`.
- [Apple's Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/)
  (D3DMetal): DirectX 11/12 to Metal translation, used by `--gfx d3dmetal`.
- [DXVK](https://github.com/doitsujin/dxvk) and
  [Gcenx's DXVK-macOS](https://github.com/Gcenx/DXVK-macOS): DirectX 9/10/11 to Vulkan,
  used with [MoltenVK](https://github.com/KhronosGroup/MoltenVK) (Vulkan on Metal) by `--gfx dxvk`.
- [Mesa 3D](https://www.mesa3d.org/) through
  [pal1000's mesa-dist-win](https://github.com/pal1000/mesa-dist-win) builds: the
  llvmpipe software renderer behind `--gfx opengl`.
- [Rosetta 2](https://developer.apple.com/documentation/apple-silicon/about-the-rosetta-translation-environment):
  runs the x86_64 runtime builds on Apple Silicon.
- Microsoft's `d3dcompiler_47.dll`, fetched from
  [mozilla/fxc2](https://github.com/mozilla/fxc2) with the same hashes
  [winetricks](https://github.com/Winetricks/winetricks) uses. Winetricks itself
  is used for the optional `--winetricks` verbs.
- [SwiftUI](https://developer.apple.com/xcode/swiftui/) for the GUI.

Inspiration for the approach (packaging a runtime so that a Windows program
behaves like a Mac app) comes from existing wrapper projects such as
[Whisky](https://github.com/Whisky-App/Whisky),
[Sikarugir (formerly Kegworks/Wineskin)](https://github.com/Sikarugir-App/Sikarugir) and
[WoWSilicon](https://github.com/WoWSilicon/WoWSilicon). Dmgexe contains no code
from them.

## Legal

Dmgexe is released under the MIT license (see [LICENSE.md](LICENSE.md)). The
third-party components listed in [Credits](#credits) are under their own terms,
and so are the programs you package. Use Dmgexe for software you are allowed to
run. Redistributing a generated `.app` that contains a program, a runtime or the
Microsoft DLL may not be permitted.

## Project layout

```
dmgexe.sh            the packager, the generated launcher and the storage commands
gui/Dmgexe.swift     SwiftUI front-end
gui/icon.svg         app icon
gui/svg2png.swift    SVG -> PNG helper used by the build
gui/build.sh         builds Dmgexe.app
tests/run.sh         test runner
tests/lib.sh         sandbox and assertions
tests/test_*.sh      the tests, by area (cli, generate, launcher, run, install, prefix, bottles,
                     winver, templates, storage, processes, gui)
tests/fixtures/      the fake Wine, wineserver, winetricks and osascript
```
