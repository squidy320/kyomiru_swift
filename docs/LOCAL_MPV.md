# Local MPV Integration

This repo vendors the `MPVKit` source under `Vendor/MPVKit`, and the app now links local XCFramework files directly from `Vendor/MPVKit/Local/xcframework`.

## What "local MPV" means here

The goal is to link local XCFramework files directly from the Xcode project instead of resolving MPV from a remote Swift package.

The app should only expose an active MPV option after these local artifacts exist and are added to `Kyomiru.xcodeproj`.

## Build the local artifacts

On a Mac with Xcode command line tools:

```bash
./scripts/prepare-local-mpv-frameworks.sh
./scripts/check-local-mpv.sh
```

Optional GPL build:

```bash
./scripts/build-mpv.sh gpl
./scripts/prepare-local-mpv-frameworks.sh
```

The expected linked output directory is:

```text
Vendor/MPVKit/Local/xcframework
```

## Build them on GitHub instead

This repo now includes a manual workflow:

```text
Actions -> Build Local MPV
```

Choose:

- `lgpl`
- `gpl`

The workflow runs on GitHub's macOS runner, prepares the full local MPV XCFramework set, and uploads a zipped artifact containing `Vendor/MPVKit/Local`.

This solves the "I do not have a Mac" part for artifact generation.

## Minimum required local XCFrameworks

The current project file expects these directories under `Vendor/MPVKit/Local/xcframework`:

- `Libmpv.xcframework`
- `Libcrypto.xcframework`
- `Libssl.xcframework`
- `gmp.xcframework`
- `nettle.xcframework`
- `hogweed.xcframework`
- `gnutls.xcframework`
- `Libunibreak.xcframework`
- `Libfreetype.xcframework`
- `Libfribidi.xcframework`
- `Libharfbuzz.xcframework`
- `Libass.xcframework`
- `Libbluray.xcframework`
- `Libuavs3d.xcframework`
- `Libdovi.xcframework`
- `MoltenVK.xcframework`
- `Libshaderc_combined.xcframework`
- `lcms2.xcframework`
- `Libplacebo.xcframework`
- `Libdav1d.xcframework`
- `Libuchardet.xcframework`

## Current app behavior

- `AVPlayer` remains the only active engine in builds where `Libmpv` is not linked.
- The MPV setting is intentionally hidden or disabled in that case so the UI does not promise a player backend that is not present.

## Next integration step

Once the full local XCFramework set exists, `Kyomiru.xcodeproj` can link the frameworks directly and the MPV player path can compile in production builds.
