# Setting up Matrix Eyes

## Requirements

- A Mac with Apple silicon (M1 or newer)
- macOS 14 Sonoma or newer
- A camera (the built-in one is fine)

## Install (one command)

Open **Terminal** (⌘Space, type "Terminal", Enter), paste this and press Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/Narek-versatile/matrix-eyes-macos/main/install.sh | bash
```

It downloads the latest release (about 45 MB), checks its SHA-256, installs **Matrix Eyes.app** into `/Applications` (or `~/Applications` if you can't write to `/Applications`) and opens it. No Xcode or developer tools needed.

## First launch

1. macOS asks whether Matrix Eyes may use the camera. Click **Allow**.
2. The app opens full screen. Digital rain falls first, then your room forms out of the code in 3D.
3. Press **Esc** for settings (the camera stops while the menu is open), **H** for the full list of keyboard shortcuts, **⌘Q** to quit.
4. Press **1–8** to change look (Matrix, Amber, Silver Surfer, Quartz, Copper, Bronze, Doodle, 3D Print). **G** puts you in space, **B** adds a black hole, **S** takes a photo (the first time, it asks which folder to keep photos in) and **T** sets a 3, 5 or 10 second countdown first.

After that, open it like any other app: Launchpad, Spotlight ("Matrix Eyes") or the Applications folder.

## Update

Run the same command again. It replaces the installed app with the latest release; your settings are kept.

## Uninstall

```bash
rm -rf "/Applications/Matrix Eyes.app" ~/Applications/"Matrix Eyes.app"; defaults delete io.github.narek-versatile.matrix-eyes 2>/dev/null; true
```

## Troubleshooting

**The screen shows only rain, never my room.** Camera access is off. Open System Settings › Privacy & Security › Camera, turn on **Matrix Eyes**, then reopen the app.

**"Matrix Eyes can't be opened because Apple cannot check it for malicious software."** This happens if you download the zip from the Releases page in a browser instead of using the command above, because the app isn't notarized. Either use the install command, or right-click the app › **Open** › **Open**, or run:

```bash
xattr -dr com.apple.quarantine "/Applications/Matrix Eyes.app"
```

**"Matrix Eyes needs an Apple silicon Mac."** Intel Macs aren't supported.

**It looks too dark or too bright.** Press **Esc** and adjust Brightness, or use ↑ / ↓.

## Build from source instead

Needs Xcode. See [Build from source](README.md#build-from-source) in the README.
