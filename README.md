# install.sh

One script to install any purpleclay tool, verified against its checksum.

## Install a product

```sh
curl -fsSL https://get.purpleclay.io | sh -s -- release-note
```

Each release is checked against its `checksums.txt`, and the binary must report the version being installed, before anything is installed. It goes into `~/.local/bin`, or `/usr/local/bin` when run as root.

```sh
# A specific version, with or without a v
curl -fsSL https://get.purpleclay.io | sh -s -- --version 0.12.0 release-note

# Into another directory
curl -fsSL https://get.purpleclay.io | sh -s -- --dir /opt/bin release-note

# Every option
curl -fsSL https://get.purpleclay.io | sh -s -- --help
```

## Verify before running

Every release of `install.sh` has a build provenance attestation, and the same file is attached to its GitHub release. To check the script really came from this repository's release workflow before running it, with the [GitHub CLI](https://cli.github.com) logged in (`gh auth login`):

```sh
curl -fsSLO https://get.purpleclay.io/install.sh &&
  gh attestation verify install.sh --repo purpleclay/install.sh \
    --signer-workflow purpleclay/install.sh/.github/workflows/release.yml &&
  sh install.sh release-note
```

Each command only runs if the one before it succeeded, so the script never runs unverified. To also check it's a particular release, rather than any release, download that release's copy and pin its tag:

```sh
gh release download v0.2.0 --repo purpleclay/install.sh --pattern install.sh &&
  gh attestation verify install.sh --repo purpleclay/install.sh \
    --signer-workflow purpleclay/install.sh/.github/workflows/release.yml \
    --source-ref refs/tags/v0.2.0 &&
  sh install.sh release-note
```
