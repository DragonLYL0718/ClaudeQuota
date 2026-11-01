# Claude 额度 (ClaudeQuota)

A macOS desktop widget that shows the usage limits of two (up to four) Claude accounts at once.

- **Menu bar app**: logs in to each claude.ai account separately and reads the same usage numbers as the claude.ai settings page on a timer (2–15 minutes).
- **WidgetKit widget** (small / medium / large): the outer ring is the 5-hour session window, the inner ring is the weekly limit. The large size adds per-model weekly limits (Fable, Opus, Sonnet, Design) and extra-usage spend.
- Colours: blue below 70%, orange from 70%, red and bold from 90%. In the system's monochrome desktop style the ≥90% state also gets an icon.

## Build

Requires Xcode 15 or later and Homebrew.

```sh
./build.sh
```

The script installs [XcodeGen](https://github.com/yonaskolb/XcodeGen) if needed, generates the Xcode project from `project.yml`, builds a Release build and installs it to `/Applications/ClaudeQuota.app`.

## Use

1. Open **Claude 额度**. In its settings, click **登录…** for each account and sign in to claude.ai.
2. Right-click the desktop → **Edit Widgets**, search for **Claude 额度**, and drag a size onto the desktop.
3. Optionally turn on **开机时自动启动** so the numbers keep updating after a restart.

**Email login**: claude.ai emails a sign-in link, which your mail app opens in the default browser rather than in the login window. Either copy the link from the email and paste it into the bar at the top of the login window, or open it in the browser and type the verification code it shows into the login window.

If the built-in login page doesn't work for an account, use **… → 粘贴 sessionKey…** with the `sessionKey` cookie copied from a browser where you are logged in to claude.ai.

## How it works

- Each account has its own WebKit data store, so two logins never mix. Requests run inside a hidden web view on claude.ai, the same way the website itself asks for usage.
- The app writes the latest numbers to `~/Library/Application Support/ClaudeQuota/snapshot.json`. The sandboxed widget reads only that file (via a read-only sandbox exception), so no App Group or paid developer account is needed; the build is signed ad hoc.

## Caveats

- The usage numbers come from claude.ai's internal web API, which is not a public API and may change without notice.
- Logins are stored locally on this Mac only. Nothing is sent anywhere except claude.ai.
