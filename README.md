<p align="center">
  <img src="docs/icon.png" width="128" alt="Quota Rings icon">
</p>

<h1 align="center">Quota Rings</h1>

<p align="center">A macOS desktop widget that shows the usage limits of your Claude and ChatGPT accounts as rings. Chinese name: 额度环.</p>

<p align="center">
  <img src="docs/widget-large.png" width="344" alt="Large widget with four accounts">
</p>
<p align="center">
  <img src="docs/widget-medium.png" width="344" alt="Medium widget with two accounts in dark mode">
  <img src="docs/widget-small.png" width="164" alt="Small widget with one account">
</p>

## Features

- **Claude and ChatGPT.** Claude accounts show the 5-hour and weekly limits from claude.ai. ChatGPT accounts show the Codex 5-hour and weekly limits from chatgpt.com. ChatGPT's chat message caps are not available from any endpoint, so they are not shown.
- **One account or many** (up to eight). Each account logs in in its own isolated web data store, so the logins never mix. Drag accounts in Settings to change their order.
- **Layouts for every count.** Each size lays itself out for the number of accounts it shows: one account gets a large ring with details, two sit side by side, and more become a grid (small), a row (medium) or a list (large). A page holds up to 4 accounts on small and medium and 6 on large.
- **Choose accounts per widget.** Right-click a widget → **Edit Widget** to pick which accounts it shows. With none picked it shows all of them. If all selected accounts are removed, it asks you to choose accounts again.
- **Pages.** When there are more accounts than fit, the widget splits them into even pages; click below the title row to turn the page. A page dot turns orange or red when an account on that page is at 70% or 90%.
- **Refresh from the widget.** Every size has a title row with the update time and a **↻ Refresh** button. Click it to fetch new numbers right away: it turns blue and reads **Refreshing** until they arrive. Failed updates keep the last good numbers with a warning. The title reflects the oldest successful update among the displayed accounts, and data older than 20 minutes is marked as stale.
- **Dual rings.** The outer ring is the shorter window (5 hours) and the inner ring the longer one (the week). Accounts with only one window get a single ring.
- **Pace hint.** Projects the average rate so far in each window and warns when you would run out before it resets. Already exhausted limits take priority; failed, stale or missing data does not produce a forecast.
- **Per-model limits and extra usage** (large size, Claude), when your plan has them.
- **Readable at a glance.** Blue below 70%, orange from 70%, red and bold from 90%. The 90% state also gets an icon, so it stays visible in the monochrome desktop style macOS uses when another app is in front.
- **Chinese or English.** Pick the language in Settings, or follow the system language. The widget follows the app. The Edit Widget panel follows the system language.

## Requirements

- macOS 14 Sonoma or later
- Xcode 15 or later, and Homebrew (to build)

## Build and install

```sh
./build.sh
```

The script installs [XcodeGen](https://github.com/yonaskolb/XcodeGen) if needed, generates the Xcode project from `project.yml`, and builds a Release build with a fresh build number. It stages and validates the new app before replacing `/Applications/QuotaRings.app`, restoring the previous app if replacement fails. After installation it removes older `ClaudeQuota.app` copies and restarts the widget.

Use `./build.sh --build-only` (or `--no-install`) to build without installing or restarting the app. Run `./test.sh` for the unit tests and installation rollback tests. Tests run without launching the menu bar app or using saved accounts; installation tests use temporary directories. CI runs both commands on macOS.

Run `./Tools/render-ui-previews.sh` to generate widget previews and contact sheets in `build/ui-previews`. The synthetic scenarios cover all sizes, both languages, light/dark/monochrome appearances, paging, long names, and missing or failed data without reading saved accounts.

## Use

1. Open **Quota Rings**. Its settings window opens the first time; later, use the gauge icon in the menu bar → **Settings…**.
2. Click **Add Account** and choose Claude or ChatGPT. Name the account, then click **Log In…** and sign in in the window that opens. It closes by itself once you are logged in.
3. Right-click the desktop → **Edit Widgets**, search for **Quota Rings**, and drag the size you want onto the desktop.
4. Turn on **Open at login** so the numbers keep updating after a restart.

### Logging in with email

claude.ai emails a sign-in link, and your mail app opens it in the default browser rather than in the login window. Either:

- right-click the link in the email, choose **Copy Link**, paste it into the bar at the top of the login window and click **Open Link**; or
- open the link in the browser, which then shows a verification code, and type that code into the login window.

### sessionKey fallback

If the built-in login page doesn't work for a Claude account, open the **…** menu next to it and choose **Paste sessionKey…**, using the `sessionKey` cookie copied from a browser where you are logged in to claude.ai (Developer Tools → Application → Cookies).

## How it works

- A menu bar app keeps one WebKit data store per account and reads the numbers from inside a hidden web view, so requests look like the logged-in website. For Claude it asks claude.ai for `/api/organizations/{org}/usage`, the same request the claude.ai settings page makes. For ChatGPT it takes the web session's access token and asks chatgpt.com for `/backend-api/wham/usage`, the endpoint the Codex CLI uses. It refreshes every 2–15 minutes, after the Mac wakes and when you click the widget's refresh button. Successful sessions are reused, with at most three accounts fetching concurrently. Individual requests and complete refresh batches have deadlines; requests made during a refresh are merged, and results from an old login are discarded.
- Each service is one file in `App/Services/` behind a small `ServiceClient` protocol, so adding another service doesn't touch the rest of the app.
- The app writes the latest numbers to `~/Library/Application Support/ClaudeQuota/snapshot.json`. The folder keeps the app's former name, as do the bundle identifiers, so logins and settings carried over from Claude Quota. The sandboxed widget reads only that file, through a read-only sandbox exception, so no App Group or paid developer account is needed. Builds are signed ad hoc.
- The widget's page is kept in the widget extension's own defaults when you click it.
- The widget can't reach claude.ai or chatgpt.com from its sandbox, so its refresh button posts a distributed notification that tells the app to refresh, or launches the app if it isn't running. The button then waits up to 15 seconds for the new snapshot, since WidgetKit redraws the widget as soon as the button's action finishes. The button is a toggle that is never on: WidgetKit shows a clicked toggle's new state straight away, which is how it can read Refreshing before the refresh ends, and the redraw afterwards turns it back.
- The widget uses dynamic date text for countdowns and update times, with a sparse timeline for forecasts, resets and stale-data warnings. The app compares all visible quota fields before asking WidgetKit to reload, and manual refreshes force an update.
- Account settings are recovered record by record if decoding fails. Unreadable originals are retained in recovery backups rather than overwritten at startup; Settings shows a recovery notice. Removing an account cancels its requests and schedules cleanup of its isolated login store.

## Project layout

| Path | Contents |
| --- | --- |
| `App/` | Menu bar app: accounts, login window, settings, refresh loop |
| `App/Services/` | One client per service (claude.ai, chatgpt.com) and the hidden web view they share |
| `Widget/` | WidgetKit extension: layouts per size and account count, account picker and paging |
| `Shared/` | Snapshot model, formatting and the two languages |
| `Resources/` | Asset catalog with the app icon |
| `Tools/` | Asset rendering, synthetic UI previews, and safe app installation |
| `Tests/` | Unit tests and isolated installation rollback tests |
| `project.yml` | XcodeGen spec (the `.xcodeproj` is generated and not committed) |

## Caveats

- The numbers come from claude.ai's and chatgpt.com's internal web APIs, which are not public and may change without notice.
- Logins are stored only on this Mac. The app talks to nothing except claude.ai and chatgpt.com.
- This is an independent project, not affiliated with or endorsed by Anthropic or OpenAI.
