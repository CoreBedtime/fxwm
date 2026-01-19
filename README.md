# Basalt

<div align="center">

![Project Logo](project-logo.png)

</div>

A Work-In-Progress Desktop Environment for macOS.

**⚠️ WARNING: EXTREMELY EXPERIMENTAL ⚠️**
This project interacts with low-level macOS WindowServer components and modifies system launch configurations via temporary overlays.

## Overview

Basalt (internal name `fxwm`) is an experimental window manager and desktop environment renderer for macOS. It utilizes code injection to allow itself to render custom UI elements _directly on screen_ using Metal. 

## Current State

- **Metal Renderer:** High-performance 2D rendering engine that replaces the compositor.
- **Custom UI Framework:** Lightweight, retain-mode UI system supporting view hierarchies (`PVView`) and interactive controls (`PVButton`).
- **Input Handling:** Processes mouse events for custom UI interaction (Hover, Click states).
- **Text Rendering:** Custom bitmap font rendering engine.
- **System Injection:** Uses `tmpfs` overlays to safely inject libraries into restricted system paths without permanent modification.

## Architecture

- **`manager/`**: The core logic loaded into WindowServer. Contains the Metal renderer, UI framework, font engine, and event hooks.
- **`src/`**: The bootstrap loader. Handles the read-write overlay creation and injection setup to override the system process.

## Building and Running

Prerequisites:
- macOS (Apple Silicon/aarch64)
- [Nix](https://nixos.org/download.html) with Flakes enabled.

### Build

```bash
nix build
```

### Run

To run the compositor injection (requires root privileges to mount overlays and restart WindowServer):

```bash
nix run
```

*Note: This will restart your WindowServer, forcing a logout. Ensure you have saved all work before running.*
