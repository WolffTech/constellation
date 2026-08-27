<!-- SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech> -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Privacy

Constellation is a macOS app for opening SSH, VNC and RDP sessions to
machines you configure. It is made by Wolff.Tech.

## What the app stores on your Mac

- The machine library (names, addresses, tags, connection profiles) in
  `~/Library/Application Support/Constellation/library.sqlite`.
- RDP certificate decisions (host, port, fingerprint, subject) in
  `~/Library/Application Support/Constellation/trust.sqlite`.
- Saved passwords and passphrases in the macOS login Keychain, as items
  labelled "Constellation credential".
- Terminal appearance settings and window state in the app's preferences.

SSH host keys are handled by the system's OpenSSH and stored in
`~/.ssh/known_hosts`, as with any ssh client. If you turn on "Use my Ghostty
configuration", the app reads the same config files Ghostty does
(`~/.config/ghostty/` and `~/Library/Application Support/com.mitchellh.ghostty/`)
and does not write to them.

## What leaves your Mac

Only the connections you start: SSH, VNC and RDP traffic to the hosts you
configure, and clipboard text for RDP profiles where you turned sharing on.
Constellation has no accounts, no analytics, no telemetry, no crash
reporting and no update checks, and contacts no server of its own.

## Support bundles

Help › Save Support Bundle… writes a zip you can attach to a report. It
contains the app and macOS versions, the hardware model, the migration state
and row counts of the databases, the protocol and connection state of open
sessions, terminal appearance settings, and the log lines the current run of
the app wrote. It does not contain machine names, addresses, account names,
passwords, clipboard contents or session output. Nothing is sent anywhere
unless you send it.

## Removing your data

Delete the app, the `~/Library/Application Support/Constellation` folder,
the `tech.wolff.Constellation` preferences, and the "Constellation
credential" items in Keychain Access.

## Contact

Questions about this policy: open an issue on the project's GitHub
repository.
