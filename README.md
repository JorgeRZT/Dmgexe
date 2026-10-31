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
- On Apple Silicon, the x86_64 translation layer must be installed.
- Xcode command-line tools (`swiftc`) to build the GUI.
- Internet access when using `--fetch-wine`, `--gfx dxvk` or `--gfx opengl`.

## Quick start

### GUI

```bash
gui/build.sh          # creates Dmgexe.app in the project root
open Dmgexe.app
```

Choose the `.exe`, check the program folder, pick a runtime source and press
**Generate .app**. The log shows progress and, when finished, buttons to reveal
or open the result.

The window has two tabs: **Generate app** creates a `.app`, and **Run program**
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
  11/12, a regular Wine with DXVK for DirectX 9, and verbs such as `vcrun2022`,
  `dotnet48` or `d3dx9` for the redistributables it links but does not ship.
  Apply only fills the form; it never overrides a runtime or backend that looks
  like a deliberate choice, and nothing changes until you press it.

This is a static guess: it says what a program can use, not what it ends up
using, and it cannot see inside packed executables. Having OpenGL in the list does
not mean the OpenGL backend is needed: programs that use OpenGL run with the
other backends through the Mac's own (hardware) OpenGL. The OpenGL backend is CPU
software rendering and shows a warning.

The app is ad-hoc signed only. If macOS blocks it, right-click it and choose
**Open**.

### Command line

```bash
./dmgexe.sh -e bin/program.exe -d /path/to/ProgramFolder -n "My Program" \
            --fetch-wine gptk --gfx d3dmetal -o ~/Desktop
```

`-e` may be absolute or relative to `-d`, and must be inside it.

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
```

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

On first launch the launcher creates a prefix in
`~/Library/Application Support/<Name>/prefix`, installs the native
`d3dcompiler_47` and the selected graphics backend, applies any winetricks verbs,
then runs the exe from its own folder. Everything the launcher does is logged to
`~/Library/Application Support/<Name>/launcher.log`; that file is the first place
to look when something fails. Switching an app from `--gfx opengl` to another
backend restores the original files in its prefix.

Downloads are cached in `~/Library/Caches/dmgexe` (override with the
`DMGEXE_CACHE` environment variable).

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
  once per prefix. Use another prefix name, or delete `.winetricks-done` in
  `~/Library/Application Support/<Name>/`, to install a changed list.

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
dmgexe.sh            the packager
gui/Dmgexe.swift     SwiftUI front-end
gui/icon.svg         app icon
gui/svg2png.swift    SVG -> PNG helper used by the build
gui/build.sh         builds Dmgexe.app
```
