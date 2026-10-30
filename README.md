# Music

A deeply customizable iOS 26 music player — themes, fonts, player layouts, word-by-word lyrics, EQ, widgets,
CarPlay. GPL-3.0, see `NOTICE.md`.
Sources: your own **Jellyfin / Navidrome / Subsonic / Octave** servers, local files, and `.8spine` extensions
(import your Deezer HiFi extension from the app's Extensions screen). The default look is the Apple Music–style
**Crimson** theme; seven more themes and a full theme editor are in **Customize**.

## Get an IPA without a Mac (about 15 minutes)

1. **Put the project on GitHub.** Make a free GitHub account → *New repository* (public is simplest and keeps
   macOS build minutes free). Unzip this project and upload everything, **including the hidden `.github` folder**
   (*Add file → Upload files* — drag the folders in). GitHub Desktop also works on Windows.
2. **Build it.** In the repo open the **Actions** tab → **Build IPA** → **Run workflow**. It takes ~10–15 minutes on a
   GitHub Mac.
3. **Download on your iPhone.** Open the repo's **Releases** page in Safari and download **Music.ipa**.
4. **Install in LiveContainer.** Open LiveContainer → **+** → choose the IPA from Files → tap the app to launch.

If Actions says it can't find the `macos-26` runner, open `.github/workflows/build-ipa.yml` and change `macos-26` to `macos-latest`.

If the build fails: Actions → the failed run → the red error lines (or the **build-log** artifact). Send me those
lines and I'll fix them.

## What works in LiveContainer
Works: playback, background audio, Lock Screen / Control Center now-playing, lyrics, EQ, themes and all
customization, all music sources. **Doesn't work** (needs real Apple signing): home-screen widgets, Live Activity /
Dynamic Island, CarPlay, Siri Shortcuts, app-group sharing.

## Rename the app
Edit `Config/Brand.xcconfig` (name, bundle id, tagline), commit, run the workflow again. Four strings used in
widget / App Intents metadata must be literals — search the code for `"Music"` in `Music/Intents.swift`,
`MusicWidgets/MusicWidgets.swift` and `Shared/PlaybackShared.swift`.

## Layout
`Music/` app · `MusicWidgets/` widgets & Live Activity · `Shared/` shared code · `project.yml` XcodeGen spec ·
`Config/Brand.xcconfig` the name.
