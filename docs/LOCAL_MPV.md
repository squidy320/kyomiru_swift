# Local MPV Integration

This repo vendors the `MPVKit` source under `Vendor/MPVKit`, and the app links local XCFramework files from `Vendor/MPVKit/Local/xcframework`.

The intended default model is CI-managed:

- the Xcode project points at `Vendor/MPVKit/Local/xcframework`
- GitHub Actions prepares that folder on the macOS runner before the archive build
- Actions cache is used so MPV does not need to be rebuilt every run

## What "local MPV" means here

The goal is to link local XCFramework files directly from the Xcode project instead of resolving MPV from a remote Swift package.

The app should only expose an active MPV option after those local artifacts exist at build time and are linked in `Kyomiru.xcodeproj`.

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
- `commit_to_repo = true` if you want the workflow to commit `Vendor/MPVKit/Local` back to `main`

The workflow runs on GitHub's macOS runner, prepares the full local MPV XCFramework set, and uploads a zipped artifact containing a top-level `Local/` folder.

This solves the "I do not have a Mac" part for artifact generation. You can still download the artifact if you want to inspect or reuse the generated frameworks locally.

If you want to install the artifact manually, extract the `Local/` folder into:

```text
Vendor/MPVKit/Local
```

and commit those files.

On Windows, use:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-local-mpv-artifact.ps1 -ArtifactZip C:\path\to\Kyomiru-MPV-lgpl.zip
```

If you run the workflow with `commit_to_repo = true`, you can skip the manual download/install step entirely. The workflow will push `Vendor/MPVKit/Local` directly to `main`.

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

## CI behavior

The main app workflow now prepares the MPV frameworks automatically on GitHub's macOS runner before building the app. If MPV build inputs do not change, the Actions cache should keep later runs much faster.
