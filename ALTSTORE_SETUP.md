# AltStore Source: Setup and Release Guide

**Purpose:** explains how the EZCompleteUI AltStore source is hosted from this repo, the one-time setup, and the routine for shipping each new version. Update this file if the release process changes.

**Source URL (what users add to AltStore):**

```
https://raw.githubusercontent.com/Tweaker177/EZCompleteUI/main/apps.json
```

## How it works

| File | Role |
| --- | --- |
| `apps.json` | The AltStore source. Users subscribe to its raw URL. |
| `.github/workflows/update-altstore-source.yml` | Runs when a release is published and commits the updated `apps.json`. |
| `.github/scripts/update_altstore_source.py` | Reads the IPA (bundle ID, version, size, SHA-256, privacy strings) and writes the new version entry. |

The IPA itself lives on the GitHub release. `apps.json` only points at it using a tag-specific URL, so an entry can never point at a newer file than the size and hash it describes.

`apps.json` currently lists **v7.0.9**, the newest release that has an IPA attached. Its size (9,497,791 bytes), SHA-256, bundle ID and minimum iOS version were checked against the real file.

## One-time setup

1. **Add the three files to the repo** at the same paths shown above (`apps.json` at the repo root). Commit them to `main`.
2. **Allow the workflow to push.** In the repo go to Settings > Actions > General > Workflow permissions. If it is set to "Read repository contents", switch to "Read and write permissions" and save. The workflow requests write access itself, but an account-level restriction can override it.
3. **Check branch protection.** If `main` is protected (Settings > Branches), add an exception so `github-actions[bot]` can push, or the workflow will fail at its last step.
4. **Confirm the source loads.** Open the source URL above in a browser. You should see the JSON. GitHub's raw host caches for about five minutes, so wait a moment after each commit.
5. **Add it in AltStore on your phone.** AltStore > Browse > Sources > `+`, paste the URL. Or open this link on the device: `altstore://source?url=https://raw.githubusercontent.com/Tweaker177/EZCompleteUI/main/apps.json`
6. **Test one full install** on a device before announcing it (see "Read this before you announce it" below).

Optional: put the `altstore://` link in the README so users can add the source in one tap.

## Fixing v7.1.4 (published without an IPA)

The v7.1.4 release currently contains only source archives, so it cannot appear in the source yet.

1. Build with `./build.sh release`. Use `release`, not the default `debug`, so the public IPA has no debug tools.
2. Edit the v7.1.4 release on GitHub and attach the `-release.ipa` file.
3. Run the workflow by hand: Actions > "Update AltStore Source" > Run workflow > tag `v7.1.4`.
4. Confirm a new commit "Update AltStore source for v7.1.4" appears on `main`.

## Routine for every future version

1. Bump the version in `Resources/Info.plist` and `control`.
2. `./build.sh release`
3. On GitHub: Releases > Draft a new release, create the tag, and **attach the `-release.ipa`** (and the `.deb` if you ship one).
4. Click **Publish release**. Publishing a draft that already has its IPA is the reliable path.
5. Watch the run under the Actions tab. When it finishes, the new version is live in AltStore within a few minutes.

The workflow ignores drafts, pre-releases, and any IPA with "debug" in its name. If two IPAs are attached, it uses the one ending in `-release.ipa`.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Workflow fails: "No release IPA was attached" | The release has no `.ipa` asset. Upload it, then run the workflow manually with the tag. |
| Workflow fails: "bundle identifier ... is not in the source" | The IPA's bundle ID differs from `com.i0stweak3r.ezcompleteui`. Fix the build, or update the ID in `apps.json` on purpose. |
| Workflow fails at push | Branch protection or Actions permissions. See setup steps 2 and 3. |
| AltStore says the download size does not match | `apps.json` was edited by hand or the asset was replaced after the workflow ran. Re-run the workflow for that tag. |
| Source shows an old version | Raw hosting cache (about 5 minutes), or AltStore has not refreshed. Pull to refresh in Browse. |
| Two releases published back to back | Handled. Runs are queued, not run in parallel. |

## Read this before you announce it

This app was built for jailbroken devices, and AltStore installs are a different environment. I could not test an on-device install from here, so check these on a real device:

- **Private entitlements.** `ent.plist` requests entitlements such as `com.apple.private.security.storage.UserSelectableAddressableFiles.read-write` and `com.apple.UIKit.vends-view-services`. AltStore re-signs with a normal developer profile, which cannot grant these. The app should still install, but features that depended on them (the document picker, opening files outside the sandbox) may behave differently.
- **Bundle ID rewrite.** With a free Apple ID, AltStore changes the bundle ID to add your team ID. Anything that keys off the exact bundle ID will break. That includes the keychain access group in `ent.plist`, and any server-side check of the bundle ID in your edge functions.
- **Separate data.** A sideloaded copy and a jailbreak `.deb` install are different apps with separate data and keychain.
- **Free account limits.** Apps must be refreshed every 7 days and free accounts are limited to three active sideloaded apps. Say so on your FAQ.
