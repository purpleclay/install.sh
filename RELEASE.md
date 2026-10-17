# Releasing

A release is a signed tag on `main`. Pushing it deploys `install.sh` to `get.purpleclay.io` and publishes a GitHub release with a generated release note. Nothing needs bumping first: the deployed script takes its version from the tag.

## Versioning

Tags are `vX.Y.Z`, and the version tracks what people running the installer see:

- **Major**: anything users or their scripts must change for, such as a renamed or removed flag or environment variable, a new default install directory, or output that scripts read changing.
- **Minor**: new flags, environment variables or supported platforms.
- **Patch**: fixes, dependency updates and documentation.

## Cutting a release

1. Check `main` is green and holds everything meant for this release:

   ```sh
   git log "$(git describe --tags --abbrev=0)..main" --oneline
   ```

2. Tag `main` with a signed tag, and push it:

   ```sh
   git tag -s vX.Y.Z -m "chore: release for vX.Y.Z"
   git push origin vX.Y.Z
   ```

3. The `release` workflow then runs four jobs:
   - **verify** checks the tag is a `vX.Y.Z` signed by `purpleclay`, on a commit of `main` whose `ci` run passed. If `ci` hasn't finished yet, wait for it, then re-run the workflow.
   - **build** sets the script's version from the tag, and attests it with build provenance.
   - **deploy** waits for your approval in the `release` environment, deploys that script to Cloudflare, and checks `get.purpleclay.io` serves it.
   - **publish** generates the release note, and creates the GitHub release with the same `install.sh` attached.

4. Check the live script reports the new version:

   ```sh
   curl -fsSL https://get.purpleclay.io | sh -s -- --help
   ```

## Fixing a bad release

Don't change it. Releases can't be edited once published, and `get.purpleclay.io` always serves the last deploy, so fix forward with a new patch release.
