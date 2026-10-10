# Retro Console

A retro game player for your own game files (SNES, Genesis, Game Boy, GBA, PlayStation and more), with a library, controller support and save states. It loads free libretro emulator cores that the user downloads inside the app.

This is the complete source code of Retro Console 1.1, the build offered at https://silicondevkit.com/apps/retro-console.

## Where it comes from

Retro Console was made with [SiliconDevKit](https://silicondevkit.com) from one prompt and one follow-up (both are on that page), based on the open-source [CODENAME](https://github.com/Lonkins/CODENAME) project by Lonkins (GPL-3.0). It reuses and adapts CODENAME's libretro core loader, video, audio, input and system-detection code. The code was written by an AI model from those instructions and has not been reviewed line by line.

## License

GPL-3.0, the same license as CODENAME. See `LICENSE`. The emulator cores the app downloads (Snes9x, Genesis Plus GX, mGBA, Beetle PSX) are separate projects with their own licenses, and are not part of this repository. You must own the games you play. The app does not include or download games or BIOS files.

## Build

Needs a Mac with Apple silicon and the Swift toolchain.

```
swift build -c release
```

This produces a command-line executable. The distributed app is that executable packaged as a `.app` bundle by SiliconDevKit's build worker (icon, Info.plist and ad-hoc signing), which is not part of this repository. `app.json` and `assets.json` are SiliconDevKit build files: `assets.json` fetches CODENAME's license text and core license notices into the app bundle at build time.
