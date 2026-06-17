# File-format icons

Per-format Finder document icons for every file type MacAmp can open. Each icon
is a blue document sheet with the Winamp bolt and a navy tag carrying the
uppercased extension. The base artwork is `winamp-file.svg`; the generator stamps
the tag and renders a macOS `.icns` per format.

## Generate

```sh
brew install librsvg imagemagick        # rsvg-convert + magick; iconutil ships with macOS
bash generate-file-icons.sh             # the full format list
bash generate-file-icons.sh mp3 flac    # only the given extensions
```

Output goes to `MacAmpApp/FileIcons/<ext>.icns`. The standing format list lives in
`DEFAULT_EXTS` at the top of the script and must stay in sync with the
`CFBundleDocumentTypes` entries in `MacAmpApp/Info.plist`.

## Wiring

Each `.icns` is bundled via the `MacAmpApp/FileIcons` resource path in
`project.yml` and bound to a document type in `MacAmpApp/Info.plist` through
`CFBundleTypeIconFile` (the value is the extension, e.g. `mp3`).

## Icon visibility

Media and playlist types are declared `LSHandlerRank` `Alternate`, so MacAmp
does not displace the system default opener. Finder shows a format's MacAmp icon
only for files where MacAmp is the resolved handler — i.e. the user set MacAmp as
the default opener, or no other app claims the type. Types MacAmp effectively
owns (e.g. `eqf`) show their icon out of the box.

## Adding a format

1. Add the extension to `DEFAULT_EXTS` and re-run the generator.
2. Add a matching `CFBundleDocumentTypes` entry in `Info.plist` with
   `CFBundleTypeIconFile` set to the extension.
3. Regenerate the Xcode project (`xcodegen generate`).
