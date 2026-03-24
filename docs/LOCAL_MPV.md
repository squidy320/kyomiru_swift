# Local MPV Integration

This repo currently vendors the `MPVKit` source under `Vendor/MPVKit`, but it does not yet contain built local MPV binaries.

## What "local MPV" means here

The goal is to link local XCFramework files directly from the Xcode project instead of resolving MPV from a remote Swift package.

The app should only expose an active MPV option after these local artifacts exist and are added to `Kyomiru.xcodeproj`.

## Build the local artifacts

On a Mac with Xcode command line tools:

```bash
./scripts/build-mpv.sh
./scripts/check-local-mpv.sh
```

Optional GPL build:

```bash
./scripts/build-mpv.sh gpl
```

The expected output directory is:

```text
Vendor/MPVKit/dist/release
```

## Build them on GitHub instead

This repo now includes a manual workflow:

```text
Actions -> Build Local MPV
```

Choose:

- `lgpl`
- `gpl`

The workflow runs on GitHub's macOS runner, builds the local MPVKit outputs, and uploads a zipped artifact containing the generated files from `Vendor/MPVKit/dist/release`.

This solves the "I do not have a Mac" part for artifact generation.

## Minimum required local outputs

The current player integration expects at least these files:

- `Libmpv.xcframework.zip`
- `Libavcodec.xcframework.zip`
- `Libavdevice.xcframework.zip`
- `Libavfilter.xcframework.zip`
- `Libavformat.xcframework.zip`
- `Libavutil.xcframework.zip`
- `Libswresample.xcframework.zip`
- `Libswscale.xcframework.zip`

## Current app behavior

- `AVPlayer` remains the only active engine in builds where `Libmpv` is not linked.
- The MPV setting is intentionally hidden/disabled in that case so the UI does not promise a player backend that is not present.

## Next integration step

Once the local MPV artifacts exist, patch `Kyomiru.xcodeproj` to link the local frameworks directly and then re-enable the MPV player path for production builds.
