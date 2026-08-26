# Security

## Reporting a vulnerability

Use GitHub's private vulnerability reporting on this repository ("Security"
→ "Report a vulnerability"). Do not open a public issue for anything that
could let a remote host, a session peer or another local user read secrets
or run code. Expect an acknowledgement within a week.

## What handles untrusted bytes

Constellation embeds three protocol engines that parse data from remote
machines in the app's own process:

| Component | Pinned at | Used for | Watch |
| --- | --- | --- | --- |
| libghostty (`Vendor/ghostty` submodule) | commit `da5ddcb0` (2026-08-22), built with Zig 0.16.0 | terminal emulation for SSH tabs | https://github.com/ghostty-org/ghostty/releases, https://github.com/ghostty-org/ghostty/security |
| FreeRDP + WinPR (`Vendor/freerdp` submodule) | tag `3.30.0` | RDP sessions | https://github.com/FreeRDP/FreeRDP/security/advisories, https://github.com/FreeRDP/FreeRDP/releases |
| OpenSSL (source build, linked statically into FreeRDPKit) | LTS release `3.5.8`, archive SHA-256 pinned in `Scripts/build-openssl.sh` | TLS and NLA for RDP | https://openssl-library.org/news/vulnerabilities/ |
| RoyalVNCKit (Swift package) | revision `92d4427c` (tag 1.1.0) | VNC sessions | https://github.com/royalapplications/royalvnc/releases |
| GRDB (Swift package) | exact `7.11.1` | SQLite storage | https://github.com/groue/GRDB.swift/releases |
| OpenSSH | the system `/usr/bin/ssh` | SSH transport | macOS security updates |

Passwords and passphrases are stored only in the login Keychain and are never
written to arguments, environment, the database or logs. Certificate decisions
for RDP live in `trust.sqlite`; SSH host keys are OpenSSH's own `known_hosts`.

## Updating a dependency

1. Check the upstream release notes and advisories for the range being
   crossed. For FreeRDP, read the GHSA entries; most are in codecs and
   channels, so also check which of those the build enables
   (`Scripts/build-freerdp.sh`).
2. Move the pin: submodule commit or tag for libghostty and FreeRDP
   (`git -C Vendor/<name> checkout <ref>`), `Package.swift` for RoyalVNCKit
   and GRDB, `ZIG_VERSION`/`ZIG_SHA256` in `Scripts/build-libghostty.sh`
   when Ghostty's `build.zig.zon` requires a newer Zig, and
   `OPENSSL_VERSION`/`OPENSSL_SHA256` in `Scripts/build-openssl.sh` for
   OpenSSL. Refresh and commit each affected `Package.resolved` after a Swift
   package change.
3. Rebuild the native kits: `Scripts/build-libghostty.sh`,
   `Scripts/build-freerdp.sh`. Both are reproducible from the scripts alone.
4. Run the full test scheme, then the environment-gated live tests against a
   real host for the protocol touched (`CONSTELLATION_TEST_RDP_*`,
   `CONSTELLATION_TEST_VNC_*`, `CONSTELLATION_TEST_SSH_*`).
5. Commit the bump on its own (`build(<component>): …`) so the history shows
   exactly which versions shipped together, then cut a release with
   `Scripts/release.sh`.

## Responding to an advisory

- Decide within a day whether the affected code is compiled in and reachable
  from a session. Feature flags in the build scripts and the settings the
  bridge pins (`constellation_rdp.c`) usually answer this.
- If it is reachable, ship a release with the fix before adding anything
  else, following the update steps above. If upstream has no fix yet, prefer
  turning the feature off in the build over waiting.
- Record the assessment in the release notes, including "not affected"
  outcomes so they are not re-investigated.
