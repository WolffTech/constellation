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
- Terminal appearance settings, window state and update settings in the
  app's preferences.
- Microsoft sign-in cookies, if you use Azure Virtual Desktop, in the app's
  web data (`~/Library/WebKit/tech.wolff.Constellation` and
  `~/Library/HTTPStorages/tech.wolff.Constellation`). They keep you signed in
  to Microsoft Entra ID so the next connection need not ask again.

SSH host keys are handled by the system's OpenSSH and stored in
`~/.ssh/known_hosts`, as with any ssh client. If you turn on "Use my Ghostty
configuration", the app reads the same config files Ghostty does
(`~/.config/ghostty/` and `~/Library/Application Support/com.mitchellh.ghostty/`)
and does not write to them.

## What leaves your Mac

- The connections you start: SSH, VNC and RDP traffic to the hosts you
  configure, and clipboard text for RDP profiles where you turned sharing on.
- Update checks. Constellation uses Sparkle to fetch its update feed and
  update downloads from the project's GitHub releases. After asking once, it
  checks automatically unless you turn that off in Settings; you can also
  check from the app menu. GitHub sees your IP address and the app version
  in the request. No other system information is sent.
- Azure Virtual Desktop sign-in, only when you add or connect to an Azure
  Virtual Desktop. The sign-in page is Microsoft's own
  (`login.microsoftonline.com`, or `login.microsoftonline.us` for Azure US
  Government), shown in a window inside the app, and what you enter there
  goes to Microsoft. Constellation then asks Azure Virtual Desktop
  (`rdweb.wvd.microsoft.com` or `rdweb.wvd.azure.us`) for your assigned
  desktops and their connection details, and connects through its gateway.
  Access tokens are kept in memory only.

Constellation has no accounts, no analytics, no telemetry and no crash
reporting, and contacts no server of its own.

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
the `tech.wolff.Constellation` preferences, the
`~/Library/WebKit/tech.wolff.Constellation`,
`~/Library/HTTPStorages/tech.wolff.Constellation` and
`~/Library/Caches/tech.wolff.Constellation` folders, and the "Constellation
credential" items in Keychain Access.

## Contact

Questions about this policy: open an issue on the project's GitHub
repository.
