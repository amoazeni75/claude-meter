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
 ACCOUNTS
 ✓ you@example.com · Max              signed in · 12s ago
     Session (5h)         █████████░░░  76%   resets in 1h 12m
     Weekly (all models)  ███████████░  92%   resets in 2d 16h
     Weekly · Fable       ███████░░░░░  61%   resets in 2d 16h
   ─────────────────────────────────────────────────────────
   other@example.com · Max                        3h ago
     Session (5h)         ██░░░░░░░░░░  12%   resets in 4h 02m
     Weekly (all models)  █████░░░░░░░  41%   resets in 5d 03h
 ─────────────────────────────────────────────────────────
 Refresh Now                                            ⌘R
 Follow Signed-in Account                                ✓
 Add Another Account…
 Forget Account                                          ▸
 ─────────────────────────────────────────────────────────
 Compact Menu Bar
 Launch at Login                                         ✓
 Open Usage on claude.ai
 ─────────────────────────────────────────────────────────
 Quit Claude Meter                                      ⌘Q
```

Every account gets its full readout, so you can see where all of them stand
without switching. The tick marks which account the menu bar follows; click
another to move it. Anything not current is greyed and carries its age.

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

## Multiple accounts

Claude Code holds exactly one credential and overwrites it whenever you switch,
so an account you are not signed into stops being readable within eight hours.
Claude Meter mirrors each account's credential into a Keychain item of its own
as you use it, and renews the ones Claude Code has let go — so every account
you have added stays live, not just the current one.

To add an account, sign into it once:

```bash
claude auth login
```

It appears in the dropdown within about thirty seconds and stays up to date
from then on, including after you switch back.

**The rule that keeps this safe:** refresh tokens rotate, so whoever refreshes
last invalidates every other holder. Claude Meter therefore renews *only*
accounts Claude Code is not signed into — it discards their credentials on
switch, which leaves Claude Meter the sole holder. The signed-in account is
always read live from Claude Code and never renewed here, because refreshing
that one would log you out of your own CLI.

If an account's refresh token is spent — usually because you signed into it
again and Claude Code rotated it — its stored credentials are dropped and it
falls back to its last reading until you next sign in.

The account driving the menu bar polls on the normal interval; the rest poll at
a fifth of that, because each extra account multiplies requests against a
rate-limited endpoint.

## Security

The app holds a live OAuth token, so it is built to give that token nowhere to
go:

- **Credentials in the Keychain, nowhere else.** Tokens for accounts you have
  added live in a Keychain item this app owns, marked
  `AfterFirstUnlockThisDeviceOnly` so nothing syncs to iCloud or off the
  machine. They are never written to disk in the clear, never logged, and never
  appear in an error message. Claude Code's own credential is read fresh on
  every request rather than cached.
- **One destination, no redirects.** The `Authorization` header is only ever
  sent to `https://api.anthropic.com/api/oauth/usage`. The URLSession delegate
  refuses every HTTP redirect, so a redirect cannot walk the token to another
  host.
- **Never refreshes the account you are signed into.** That one belongs to
  Claude Code, and refreshing it would rotate the token out from under your CLI
  and log you out. Only accounts Claude Code has already let go of are renewed.
- **No incidental persistence.** An ephemeral URLSession, with cookies and both
  caches disabled. Outside the Keychain, the only things written to disk are two
  UI preferences (`compactBar`, `didRegisterLoginItem`).
- **A public client id, not a secret.** Renewal uses Claude Code's OAuth client
  id. A native app authenticating with PKCE cannot hold a client secret, so this
  value is identical in every install and is not a credential.
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
./Tests/run.sh        # 76 assertions: parsing, layout, colour bands, account switching
./build.sh            # build only, to build/ClaudeMeter.app
./build.sh --install  # build, install to /Applications, launch
./build.sh --zip      # also produce a zip
```

| File | Role |
| --- | --- |
| `Sources/Usage.swift` | Keychain read, API client, response parsing, menu bar layout |
| `Sources/UsageBarView.swift` | The chip: border, dividers, text (geometry constants at the top) |
| `Sources/Account.swift` | Signed-in account identity and the `~/.claude.json` watcher |
| `Sources/AccountStore.swift` | Keychain-backed store of every known account |
| `Sources/TokenRefresh.swift` | Renewal for accounts Claude Code no longer holds |
| `Sources/FetchPacer.swift` | Poll spacing, backoff, and which triggers may skip them |
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
