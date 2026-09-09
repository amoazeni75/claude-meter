# Claude Meter

Your Claude usage limits, live in the macOS menu bar.

```
╭──────────────────────────────╮
│  5h 76% │ wk 92% │ fb 61%    │
╰──────────────────────────────╯
```

A rounded chip with a hairline border, each number separated by a faint rule.

- **5h** — current session window (5 hours)
- **wk** — weekly window, all models
- **fb** — weekly window for Fable (per-model cap)

Labels stay neutral; each percentage is coloured by how full that window is,
so the colour only ever means one thing:

| Usage | Colour |
| --- | --- |
| 0–50% | green |
| 50–75% | yellow |
| 75–90% | orange |
| 90–100% | red |

Bands come from the percentage alone, not from the `severity` the API also
sends, so a given number always reads the same colour.
Click for a breakdown with reset countdowns.

```
 you@example.com · Max
 ─────────────────────────────────────────────────────
 Session (5h)         █████████░░░  76%   resets in 1h 12m
 Weekly (all models)  ███████████░  92%   resets in 2d 16h
 Weekly · Fable       ███████░░░░░  61%   resets in 2d 16h
 ─────────────────────────────────────────────────────
 Updated 8s ago
 Refresh Now                                        ⌘R
 ─────────────────────────────────────────────────────
 Compact Menu Bar
 Launch at Login                                     ✓
 Open Usage on claude.ai
 ─────────────────────────────────────────────────────
 Quit Claude Meter                               ⌘Q
```

## Install

You need macOS 13+, Claude Code installed and signed in, and Xcode or the
Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/amoazeni75/claude-meter.git
cd claude-meter
./build.sh --install
```

That compiles the app, installs it to `/Applications`, launches it, and
registers it to start at login.

**On first launch macOS asks once** for permission to read the Claude Code
sign-in from your keychain. Click **Always Allow**. (Choosing *Allow* instead
means you get asked again every hour or so.)

That's it. There is nothing to configure and no account to create — it reuses
the Claude Code login you already have.

### Sharing it with someone

Send them the repo, not a built app. Those same three commands are the whole
install. Building locally also avoids the Gatekeeper warnings that an unsigned
downloaded app would trigger — this project has no Apple Developer ID, so a
prebuilt binary would be quarantined on their machine.

The app adapts to whatever plan they're on: it renders whichever limit windows
the API reports, so a Pro account with no per-model cap simply shows `5h` and
`wk`, and a model this app has never heard of gets a two-letter label
automatically.

## Where the numbers come from

`GET https://api.anthropic.com/api/oauth/usage` — the same endpoint behind
Claude Code's `/usage` command — authorized with the OAuth token Claude Code
already stores in your login keychain as `Claude Code-credentials`.

These are true account-level limits, so they include usage from the Claude
desktop app and claude.ai too, not just Claude Code.

Polling is every 60 seconds, plus on wake from sleep and when you open the
menu. The endpoint reports usage; it does not consume any.

## Switching accounts

If you sign into a different Claude account with `claude`, the app follows you:

- it re-reads the keychain on **every** poll rather than caching a token, so a
  refreshed or replaced token is picked up on its own;
- it watches `~/.claude.json` for login changes and switches within about a
  second, discarding the previous account's numbers immediately rather than
  showing stale figures under the wrong name;
- the account it is currently reporting on is named at the top of the menu, so
  the numbers are never ambiguous.

## Security

The app holds a live OAuth token, so it is built to give that token nowhere to
go:

- **Memory only.** The token is read into a local variable per request. It is
  never stored in a property, written to disk, cached, or logged, and never
  appears in an error message.
- **One destination, no redirects.** The `Authorization` header is only ever
  sent to `https://api.anthropic.com/api/oauth/usage`. The URLSession delegate
  refuses every HTTP redirect, so a redirect cannot walk the token to another
  host.
- **Read-only.** Nothing is ever written back to the keychain. The refresh
  token is not read and not used — refreshing is left entirely to Claude Code,
  so this app can never invalidate your CLI session.
- **No persistence.** An ephemeral URLSession, with cookies and both caches
  disabled. The only thing written to disk is two UI preferences
  (`compactBar`, `didRegisterLoginItem`).
- **No dependencies.** Pure Swift against system frameworks — nothing from
  SwiftPM, Homebrew, or npm, so there is no supply chain to trust.
- **Hardened runtime.** The bundle is signed with `--options runtime`, which
  blocks debugger attach and dynamic library injection against the process
  holding the token.
- **No network input.** The app listens on nothing and exposes no IPC.

macOS enforces the boundary independently: the keychain item belongs to the
`claude` binary, so this app cannot read it until you explicitly grant access,
and you can revoke that at any time in **Keychain Access → login →
`Claude Code-credentials` → Access Control**.

Everything it does is in four short Swift files; `Sources/Usage.swift` is the
only one that touches credentials or the network.

## Troubleshooting

| Menu bar shows | Meaning |
| --- | --- |
| `claude: sign in` | No Claude Code credentials in the keychain — run `claude` and log in. |
| `claude: auth` | Token expired. Claude Code refreshes it the next time you use it, then this clears on its own. |
| `claude: keychain` | You denied the keychain prompt. Grant access in Keychain Access → `Claude Code-credentials` → Access Control. |
| `claude —` | Network or API error. Open the menu for the specific message. |
| greyed-out numbers | Last known values, but the most recent refresh failed. |

**It asks for keychain access again after I rebuild.** Expected. The ad-hoc
signature changes on every build, and macOS ties the grant to the exact
binary. Click Always Allow once more.

## Development

```bash
./Tests/run.sh        # 47 assertions: parsing, layout, colour bands, account switching
./build.sh            # build only, to build/ClaudeMeter.app
./build.sh --install  # build, install to /Applications, launch
./build.sh --zip      # also produce a zip
```

| File | Role |
| --- | --- |
| `Sources/Usage.swift` | Keychain read, API client, response parsing, menu bar layout |
| `Sources/UsageBarView.swift` | The chip: border, dividers, text (geometry constants at the top) |
| `Sources/Account.swift` | Signed-in account identity and the `~/.claude.json` watcher |
| `Sources/StatusController.swift` | Status item, dropdown, polling, launch-at-login |
| `Sources/main.swift` | Entry point and single-instance guard |
| `Tools/make-icon.swift` | Draws the app icon; `build.sh` runs it through `iconutil` |

The build produces a universal binary (arm64 + x86_64), so the same app runs on
Apple Silicon and Intel.

## Uninstall

```bash
osascript -e 'quit app "ClaudeMeter"'
rm -rf /Applications/ClaudeMeter.app
defaults delete com.claudemeter.app
```

Removing the app also removes its login item. To revoke keychain access, delete
this app's entry under `Claude Code-credentials` → Access Control in Keychain
Access.

## License

MIT. Not affiliated with Anthropic.
