[← Back to the README](../README.md)

# Releasing

Every version is a git tag, and every tag becomes a release on the
[Releases page](https://github.com/Louistuis/cursor-pilot/releases), built on
GitHub's own Macs by [`.github/workflows/release.yml`](../.github/workflows/release.yml).
Nothing is built or uploaded from anyone's own machine.

## Publish a version

```bash
git tag v0.2.0
git push origin v0.2.0
```

The workflow sets the app's version from the tag (`CFBundleShortVersionString`
0.2.0, and the run number as the build number), builds the Rust core and the
app, checks the signature, zips it and publishes **Cursor Pilot 0.2.0** with
`Cursor-Pilot.zip` and its SHA-256. The release notes are the install steps in
[`.github/release-notes.md`](../.github/release-notes.md) followed by the
changes since the last tag.

The asset always has the same name, so
`https://github.com/Louistuis/cursor-pilot/releases/latest/download/Cursor-Pilot.zip`
always downloads the newest version.

Use [semantic versions](https://semver.org): `v0.2.1` for fixes, `v0.3.0` for
new features. A tag with a suffix, such as `v0.3.0-beta.1`, is still published;
mark it as a pre-release on its release page so it doesn't become "latest".

## Try a build without publishing

Actions › Release › **Run workflow** builds the current branch and attaches the
zip to the run as an artifact. Nothing is published.

## Change or withdraw a version

- **Edit the notes, or mark it as a pre-release:** Edit on its release page, or
  `gh release edit v0.2.0 --prerelease`.
- **Pull a bad version:** `gh release delete v0.2.0 --cleanup-tag`. The
  "latest" download link falls back to the previous release.
- **Replace a broken build of the same version:** delete the release and its
  tag as above, fix it, then tag and push again.

## Signing

Releases are signed ad hoc, so on first launch macOS asks people to allow the
app in System Settings › Privacy & Security, and permissions may need granting
again after an update. A paid Apple Developer ID would let the workflow sign
with a stable identity and notarise the app, which removes both. That needs the
certificate and an app-specific password stored as repository secrets.
