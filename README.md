# fxwm

A low-level window manager experiment for macOS that hooks into the SkyLight compositor layer.

## What it does

fxwm injects into the macOS WindowServer process and takes over rendering. It:

- Stops all normal WindowServer rendering (windows, desktop, dock, etc.)
- Preserves cursor rendering
- Draws an animated 3D colored cube using Metal

## Components

- **fxwm** - The injector binary that sets up the dylib injection via tmpfs overlay
- **libprotein_render.dylib** - Hooks SkyLight functions and implements custom Metal rendering
- **metal_renderer** - Separated Metal rendering code (cube shader, 3D math, animation)

## Building

Requires Nix with flakes enabled:

```bash
nix build
```

The build produces arm64e binaries (Apple Silicon with pointer authentication).

## Running

```bash
nix run
```

Or manually:

```bash
sudo ./result/bin/fxwm
# Then `launchctl reboot userspace` to apply the WindowServer injection.
```

## Requirements

- macOS on Apple Silicon (arm64e)
- Xcode Command Line Tools
- System Integrity Protection OFF (for WindowServer injection)

## Technical Details

- Uses [Dobby](https://github.com/jmpews/Dobby) for function hooking on arm64e
- Resolves private symbols via dyld shared cache parsing
- Hooks `CGXUpdateDisplay` to inject custom rendering 
- Renders via `CAMetalLayer` on a root `CAContext` with a custom Metal pipeline
- Uses tmpfs overlay on `/System/Library/LaunchDaemons` to inject `DYLD_INSERT_LIBRARIES`

## License

Research/experimental use only.
