# A Hardware-Accelerated Linux Desktop on a Phone

[简体中文](../../README.md) | **English**

---

Turn an Android phone into a Linux machine running a **GPU-accelerated XFCE desktop**: Termux host + proot Ubuntu 24.04 container, **VNC and Termux:X11 live side by side**, OpenGL through Adreno KGSL natively (no zink translation), Vulkan through Turnip.

This repo is not the driver — it's **the layer above the driver**: how to bring the display services up, how to configure the GPU environment, why Electron apps can't see the GPU, and how to make all of it survive `apt upgrade` and app-store self-updates.

> [!NOTE]
> Every conclusion here comes from **measurement on the actual device**, not from documentation. What doesn't work is stated plainly under [Known issues](#known-issues); nothing is hidden.

---

## Features

- **Two displays at once** — `:1` TigerVNC (can stay resident in the background, reachable remotely) and `:2` Termux:X11 (low-latency local output), each with its own session and its own D-Bus bus. They don't interfere; both desktops can run simultaneously.
- **Native Adreno OpenGL** — `MESA_LOADER_DRIVER_OVERRIDE=kgsl`, skipping zink's GL→Vulkan translation overhead.
- **Turnip Vulkan** — works on Adreno 8xx; see below for the VNC-side swapchain workaround.
- **A GPU fix for Electron that works across versions** — the most distinctive part of this repo. An `LD_PRELOAD` shim supplies the PCI device enumeration Chromium expects, then flags are **selected automatically by Chromium major version**, so one script covers Electron apps of widely different vintages.
- **User-level, update-proof** — everything lands in `~/.local/lib/` and `~/.config/`; `/usr/local/bin` holds only symlinks. `apt upgrade` and app-store self-updates can't clobber it, deleting the directory is a full rollback, and nothing dpkg owns is ever touched.

---

## Compatibility

| Device | SoC | GPU | Container | OpenGL | Vulkan | Note |
| :-: | :-: | :-: | :-: | :-: | :-: | :-- |
| **Redmi K90 (standard edition)** | Snapdragon 8 Elite | **Adreno 830v1** | proot Ubuntu 24.04 | ✔ native kgsl | ✔ Turnip | source of every finding here (in use as of 2026-09; GPU model read from glxinfo/vulkaninfo) |
| **Redmi K60** | Snapdragon 8+ Gen 1 | **Adreno 725** | proot Ubuntu 24.04 | ✔ zink | ✔ Turnip | earlier setup, different recipe — see below |

> [!IMPORTANT]
> **The K60-era recipe is wrong on Adreno 830.** Back then the VNC side relied on "the four zink variables + `-rendernode /dev/kgsl-3d0` + `+iglx`". Now that the kgsl backend is mature, the right move is to launch `Xvnc` directly and go through the native kgsl path. The scripts keep both generations side by side in their comments — follow the comments when migrating; don't copy the old variables over verbatim.

For the driver itself use a Release from [**lfdevs/mesa-for-android-container**](https://github.com/lfdevs/mesa-for-android-container); this repo doesn't rebuild it.

---

## The host side: Termux and Termux:X11

This part has more pitfalls than the container, and almost no documentation.

### What a self-signed Termux fork costs you

The host on the K90 is **ZeroTermux**, a third-party Termux fork. It ships with its own signing key, and therefore:

> [!WARNING]
> **No official Termux plugin will install**, failing with `INSTALL_FAILED_SHARED_USER_INCOMPATIBLE (-8)`.
> Termux plugins share a `sharedUserId` with the main app, and Android requires both to carry the same signature. The official Termux:X11 APK is signed by the Termux project, ZeroTermux is self-signed, so **the signatures don't match and the package manager refuses outright** — regardless of whether the APK itself is fine.

Two ways out:

1. use the matching plugins ZeroTermux distributes itself (same signature), or
2. move to official Termux wholesale, then install the official Termux:X11.

Do **not** try `adb install -r`, downgrades, or renaming the package. The `sharedUserId` signature check lives in the package manager; there is no way around it.

### Where the startup script belongs

The host-side entry point `start.sh` **must live in the Termux home directory** (outside the container) — bringing the container up is its whole job. The copy inside the container is just that, a copy, and **the two drift apart**: this project hit exactly that, with a 3922-byte copy inside and a 9033-byte original outside. Editing the wrong one meant a 1M-context header setting that wouldn't take effect no matter what.

`termux/01-termux-bootstrap.sh` adds a **self-healing symlink**: on every launch it checks whether the script in the host home points at the canonical copy inside the container, and rebuilds it with `ln -sf` if not — which removes this class of "I edited the copy" problem at the root.

### Display on the Termux:X11 side

`files/vnc/startx11` brings `:2` up: clear stale X sockets, start `termux-x11`, start a separate D-Bus session bus, start XFCE, then sync the cursor settings. An `xdpyinfo` liveness gate that used to sit in this script **has been removed** — in practice it never caught a real failure, and it could misjudge a perfectly good desktop as a failed one and block it.

---

## GPU

### The basic environment variable

```bash
MESA_LOADER_DRIVER_OVERRIDE=kgsl     # OpenGL natively on Adreno, no zink
```

### Vulkan swapchain on the VNC side

Vulkan programs on `:1` fail to create a swapchain. The root cause is that the Xvnc in use lacks `miSyncShmScreenInit` (DRI3 / sync extension initialization).

A patched Xvnc does fix it, but measures **3.4× slower overall** — not worth it. The workaround in use routes WSI through software instead:

```bash
MESA_VK_WSI_DEBUG=sw
```

Vulkan compute and offscreen rendering stay on hardware; only presentation becomes software, which costs far less than replacing Xvnc.

---

## Electron apps and the GPU: tiers by version

This is where most of the effort went.

### The problem

A proot container **has no PCI device nodes**. Chromium's GPU process enumerates PCI devices to identify the card at startup; an empty enumeration makes it decide there is no GPU, after which no `--use-gl` flag will stop it from falling back to software rendering.

### The fix

`files/local-lib/electron-shim/fakepci.c` uses `LD_PRELOAD` to intercept device enumeration and fabricate a single Adreno entry for Chromium to accept. It then opens `/dev/kgsl-3d0` normally — you can see the `kgsl` fd in the GPU process.

> [!TIP]
> When writing a shim like this on aarch64, **`#include <stdlib.h>` is mandatory**. Without it `getenv` is treated as an implicitly declared function returning `int`, truncating the 64-bit pointer to 32 bits. The symptom is "the environment variable reads as garbage", and it only reproduces on arm64.

### The tier table

Chromium generations differ in which `--use-gl` implementations they allow, so no single set of flags can cover all of them. `files/desktop-env/electron-gpu.sh` reads the Chromium major version out of the app (caching the result under an md5 of `path|size|mtime`) and picks a tier:

| Chromium major | Tier | Flag strategy | Measured result |
| :-: | :-: | :-- | :-- |
| **≤ 144** | `kgsl` | no `--use-gl`, add `--ignore-gpu-blocklist` | ✔ real hardware GL, GPU process holds a kgsl fd |
| **≥ 145** | `swsafe` | same, plus `--enable-unsafe-swiftshader` | SwiftShader, software but stable |
| **undetected** | `safe` | no `--use-gl`, add `--ignore-gpu-blocklist` | defers to Chromium's own judgement |

There are also `off` / `full` / `egl` tiers for manual debugging. `ELECTRON_FAKEPCI=0` disables the shim.

> [!CAUTION]
> **`--use-gl=egl` looks harmless and isn't.** Adding it on Chrome 120 *dropped* the app from real hardware to SwiftShader, with three crashes along the way. So the right answer for the `safe` tier is to **pass nothing** and let Chromium decide.
>
> Separately, from Chrome 125 onward software rendering requires an explicit `--enable-unsafe-swiftshader`, or the software backend refuses to start at all.

---

## Staying alive across updates

The project's hard rule; every change obeys it:

| What | Where | Why |
| :-- | :-- | :-- |
| script / shim body | `~/.local/lib/<name>-shim/` | dpkg doesn't manage this; updates can't clobber it |
| executable entry point | `/usr/local/bin/<name>` → **symlink** | stays on PATH while the body remains replaceable |
| configuration | `~/.config/<name>/` | same, and deleting the directory is a full rollback |

> [!WARNING]
> When writing backup or collection scripts, note that **`[ -f "$f" ]` follows symlinks**. To skip a symlink you must check `[ -L "$f" ] && continue` first, or you'll collect the real file behind it — possibly under `/opt`, possibly containing something sensitive. This project made that mistake.
>
> The same applies to key scanning: a pattern like `(sk|pk|rk)-` **needs word boundaries**. Without `\b` it matches `/spark-store` and `network-switch`, and the push gets blocked by your own guard.

---

## Cursors: why dragging the slider past 48 does nothing

In XFCE's *Settings → Mouse → Cursor size*, dragging the slider had no effect on the Redmi K90 (standard edition). Reading the actual pixel size via the XFIXES `GetCursorImage` request exposed two separate causes:

1. **The themes have no large images.** All four cursor themes installed on this device (vintage / Adwaita / bloom / bloom-dark) top out at **48px**, so `XcursorLibraryLoadImage` silently falls back to 48 for any request of 64 / 96 / 128.
2. **`xfsettingsd` doesn't write xrdb.** It manages XSETTINGS (which GTK apps read) but never sets the `Xcursor.*` resources; meanwhile the root window's cursor is fixed at session start, so changing xfconf doesn't reset it.

Two tools address these:

- `tools/make-hidpi-cursor.py` — pure standard library. Takes the largest image in a theme, scales it up nearest-neighbour, and writes a new theme containing 24 / 32 / 48 / 64 / 96 / 128 into `~/.icons/`. Nearest-neighbour rather than interpolation, because cursors are hard-edged pixel art and interpolation smears the edges.
- `files/desktop-env/cursor-sync.sh` — reads xfconf → writes xrdb → resets the root-window cursor with `xsetroot`. It **only reads xfconf and never sets `XCURSOR_*`**, so xfconf stays the single source of truth and the native settings dialog isn't bypassed.

```bash
tools/make-hidpi-cursor.py vintage vintage-hidpi 24,32,48,64,96,128
files/desktop-env/cursor-sync.sh :1 :2
```

> [!NOTE]
> Most already-open windows fixed their cursor at creation time and won't change immediately; the root window and desktop change at once, and other applications pick it up when reopened. That's inherent to X, not a failure of the script.

---

## What's in this repo

Only the parts that are **general and can be lifted out as-is**. The full one-shot deployment scripts, the per-application wrappers, this K90's `.desktop` files and package lists are all device-specific and live elsewhere.

```
README.md                                  every measured finding (the bulk of this repo)
files/desktop-env/
  gpu.sh                                   GPU environment (kgsl / Turnip / WSI)
  electron-gpu.sh                          Electron tiers by Chromium version
  cursor-sync.sh                           xfconf → xrdb → root-window cursor
files/local-lib/electron-shim/
  fakepci.c                                LD_PRELOAD PCI enumeration shim (the core)
tools/
  make-hidpi-cursor.py                     multi-size cursor theme generator (stdlib only)
files/icons/
  README-光标主题重建.txt                    notes on rebuilding the cursor theme
```

> [!NOTE]
> These scripts can be taken individually; they aren't tightly coupled. `electron-gpu.sh` goes with `fakepci.c`; `cursor-sync.sh` goes with `make-hidpi-cursor.py`.

---

## Usage

```bash
# 1. build fakepci
gcc -shared -fPIC -o fakepci.so files/local-lib/electron-shim/fakepci.c

# 2. GPU environment
source files/desktop-env/gpu.sh

# 3. launch an Electron app (version detected, tier chosen automatically)
files/desktop-env/electron-gpu.sh /path/to/app

# 4. cursors: build the large-image theme, then push it to the X layer
tools/make-hidpi-cursor.py vintage vintage-hidpi 24,32,48,64,96,128
files/desktop-env/cursor-sync.sh :1 :2
```

---

## Known issues

| Issue | Status |
| :-- | :-- |
| **Black frames in video players** — with GPU presentation, 20–40% of frames come out entirely black on both displays | Unresolved. Narrowed to two candidates: Mesa's kgsl EGL/WSI clearing on swap, or Xvnc-dri3 / Xlorie mmap-ing the dmabuf `PROT_READ` without a cache invalidate. Three user-level workarounds are prepared (x11/xcb output for the players, software presentation for mpv) but not merged. |
| **Hardware path on Chrome 148** | Blocked by `EACCES` on the DRM render node; judged not worth pursuing further. |
| **Vulkan swapchain on the VNC side** | A working patch exists but runs 3.4× slower; `MESA_VK_WSI_DEBUG=sw` is used instead. |

---

## Acknowledgements

- [**lfdevs/mesa-for-android-container**](https://github.com/lfdevs/mesa-for-android-container) — the Mesa build that makes Android containers viable, and the GPU foundation this project stands on. This README's organization takes after theirs.
- [**termux/termux-x11**](https://github.com/termux/termux-x11) — the `:2` display service.
- [**TigerVNC**](https://github.com/TigerVNC/tigervnc) — the `:1` display service.
- **xMeM**, **Robert Kirkman**, **Lucas Fryzek**, **Rob Clark**, and the Termux maintainers — for the Freedreno KGSL backend and the porting work around it.

---

## License

Scripts and documentation are released under MIT. Third-party components (Mesa, TigerVNC, Termux:X11, and others) remain under their original licenses.
