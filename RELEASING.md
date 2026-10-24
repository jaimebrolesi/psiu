# Releasing Psiu

Every push to `main` and every pull request is built and tested on a GitHub Mac (`.github/workflows/build.yml`). Versions are published by `.github/workflows/release.yml` from a tag, never by hand.

1. Update the version in `build-dmg.sh`: `CFBundleShortVersionString` as `X.Y.Z` and `CFBundleVersion` one above the current one.
2. Write the release notes in `.github/release-notes-vX.Y.Z.md`, in English and Portuguese.
3. Commit and push to `main`, and wait for the build to pass.
4. Tag and push the tag:

   ```bash
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

The release workflow checks that the tag matches `CFBundleShortVersionString` and that the notes exist, then builds, verifies the signature, runs `test.sh` and publishes the release with `Psiu.dmg` and its SHA-256 (`Psiu.dmg.sha256`) attached.

To try it without publishing, run the Release workflow by hand in the Actions tab with **dry-run** on (the default).

To install on your own Mac, build locally with `bash build-dmg.sh`, or download `Psiu.dmg` from the release.
