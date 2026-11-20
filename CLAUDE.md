# CLAUDE.md

## Overview

SelfDesk is the Self-Labs branded build of the [RustDesk](https://github.com/rustdesk/rustdesk)
remote access client. It is not compiled here: the public [rdgen](https://rdgen.crayoneater.org)
service builds it from [`selfdesk.json`](./selfdesk.json), and a GitHub Actions workflow downloads the
results, adjusts the Linux packages and publishes them as a GitHub Release. The client comes
preconfigured for the self-hosted server (`rustdesk-id.selflabs.org`, port 21116) and the CortenDesk
console/API (`https://rustdesk.selflabs.org`), with no baked password.

User-facing docs (README, CHANGELOG, workflow comments, script comments) are in Brazilian
Portuguese with full accentuation. Commit messages are in English (Conventional Commits).

## Stack

- rdgen (public instance) driven by [rdgen-cli](https://github.com/AlekseyLapunov/rdgen-cli),
  pinned by `RDGEN_CLI_SHA` in the workflow because it runs with the repo token.
- GitHub Actions on `ubuntu-latest`: Python 3.12 for rdgen-cli, `dpkg-deb` for the `.deb` repack,
  `bsdtar` (libarchive-tools) and `zstd` for the Arch repack.
- `brand/build-brand.py`: Python 3 + Pillow + the Inter font, run by hand only.

## Structure

```
selfdesk.json              rdgen config (Load/Save Configuration in the rdgen UI); ~700 KB because
                           it embeds the brand images as base64. Do not read it whole.
brand/                     icon.png, logo.png, privacy.png and build-brand.py that generates them
scripts/repack-arch.sh     rewrites the rdgen .pkg.tar.zst into the selfdesk package (see below)
.github/workflows/build.yml  daily check, build (windows then linux), release
README.md                  download links, install, locked/default settings, credits (pt-BR)
CHANGELOG.md               Keep a Changelog 1.1.0, pt-BR
LICENSE                    AGPL-3.0 (from RustDesk)
```

## Build and release

- Nothing builds locally. A push to `master` does **not** trigger a build.
- The workflow runs daily at 04:23 UTC (01:23 São Paulo). It reads the rdgen default version and
  builds only when the Release `v<version>` does not exist yet. Windows and Linux run one after the
  other (`max-parallel: 1`), about 40 minutes each.
- Manual run: Actions > build > Run workflow, or
  `gh workflow run build.yml -R self-labs/selfdesk -f force=true` (optionally `-f version=X.Y.Z`,
  which must be in the rdgen `VERSION_CHOICES`). `force` deletes the existing Release **and its tag**
  and republishes only the new files, tagged at the building commit.
- Release file names carry no version, so `releases/latest/download/<file>` is a stable URL used by
  install scripts elsewhere. Never add the version to an asset name.
- Versions follow the RustDesk version the rdgen built (`v1.5.3`), not CalVer. Packaging changes
  between RustDesk versions stay in `[Unreleased]` of the CHANGELOG.
- Replacing a single asset without a rebuild (what was done for the Arch package of v1.5.3):
  `gh release upload vX.Y.Z <file> SHA256SUMS --clobber`, after fixing that file's line in
  `SHA256SUMS`. Then confirm with `sha256sum -c SHA256SUMS --ignore-missing` on a fresh download.
- Release notes are generated inline by the workflow (download table plus the AGPL-3.0 source
  links), not taken from the CHANGELOG.

## Linux package conventions

The rdgen names the binary and service after the app (`SelfDesk`). Both Linux formats are brought
to the same layout:

- `.deb` (workflow step "Comando e serviço em minúsculas nos .deb"): adds `/usr/bin/selfdesk` and
  `Alias=selfdesk.service`, then fails the job when the brand logo is missing.
- `.pkg.tar.zst` (`scripts/repack-arch.sh`): package renamed `rustdesk` -> `selfdesk` with
  `conflict = rustdesk` (otherwise the distro `rustdesk` replaces it on `pacman -Syu`),
  `SelfDesk.service` shipped in `/usr/lib/systemd/system` with `Alias=selfdesk.service` instead of
  being copied to `/etc` by `.INSTALL`, desktop files in `/usr/share/applications`, icons renamed to
  `SelfDesk.png`/`.svg` to match `Icon=SelfDesk`, and `.MTREE` regenerated with root ownership.
  Test locally: `bash scripts/repack-arch.sh <copy>.pkg.tar.zst selfdesk`, then
  `LANG=C pacman -Qip` and `pacman -Qlp` on the result. Lint with
  `uvx --from shellcheck-py shellcheck scripts/repack-arch.sh`.

## Gotchas

- **Brand images must travel as base64.** rdgen-cli posts the JSON as a form and Django drops text
  sent to the `iconfile`/`logofile`/`privacyfile` FileFields, so `selfdesk.json` carries
  `iconbase64`, `logobase64` and `privacybase64`. After regenerating `brand/`, reload the images
  through the rdgen UI (Load/Save Configuration) so the JSON is updated.
- **Hidden connection window** needs password-only approval, permanent password only and
  `allow-hide-cm`. rdgen only sets them with a baked password, so they go through `overrideManual`.
  A machine without a permanent password does not accept connections.
- **The real binary must be lowercase.** RustDesk finds its own processes with
  `ps aux | grep "<app name lowercased> --server"` (`is_server_running` in
  `libs/scrap/src/wayland/pipewire.rs`; the kill and tray patterns in `src/platform/linux.rs` do
  the same), and a process path is the resolved file, not a symlink. With the binary named
  `SelfDesk`, the Wayland server asked for the RemoteDesktop portal, which Hyprland lacks, and every
  connection failed. `repack-arch.sh` renames it to `selfdesk` and leaves `SelfDesk` as a link; the
  `.deb` still ships `SelfDesk` (fine on X11 for capture, but the same kill/tray patterns miss).
- The `key` in `selfdesk.json` is the server's **public** key; it is meant to be in the client.
- CortenDesk (`/downloads` on `rustdesk.selflabs.org`) serves its own uploaded copies of the
  `.exe` and `.deb`, stored on the server, not links to the Release. After a new Release they must be
  uploaded again by hand.
- The `actions/*@v4`/`@v5` versions in the workflow run on Node 20, which GitHub is deprecating.

## Conventions

- Default branch `master`. Commit or push only when the user asks.
- Every notable change goes into `CHANGELOG.md` `[Unreleased]` in the same change.
- No em dashes or en dashes in any file or message.
- Workflow and script comments explain why, in pt-BR, matching the existing style.
