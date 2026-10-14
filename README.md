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
