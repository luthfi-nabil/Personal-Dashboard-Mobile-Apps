# Personal Dashboard (Flutter)

A cross-platform (mobile/desktop/web) Flutter client for the **personal-dashboard**
suite — a personal finance and insulin-tracking dashboard. It is an offline-first
port of an earlier PWA, backed by [`transaction-api`](../transaction-api) and
[`health-api`](../health-api).

## Purpose

- **Dashboard** — overview of balances, recent transactions, and quick stats.
- **Transactions** — add/edit earnings and spendings, organized by source and category.
- **Scan Price List** — photograph a receipt or printed price list, drag a box
  over the part to read, then confirm/edit each recognised row before saving it
  as a spending with a line-item **transaction detail** (Android/iOS only).
- **Investment** (Finance → Investment) — reksa dana, gold and silver holdings,
  plus an **Others** section for anything else (crypto, bonds, stocks), stored
  apart from source balances because those are liquid cash and these are not. Each holding keeps a fixed cost basis plus a separately updatable
  current unit price, so gain/loss survives any number of price refreshes. See
  [Investment prices](#investment-prices).
- **Home** leads with **net worth** — liquid balances plus what the investments
  are currently worth — broken out underneath into a **Liquid** and an
  **Investment** tile that open their respective pages. The Finance overview
  keeps saying **Liquid**, since it only ever covers sources; the same is true
  of the source-balance totals in exported reports.
- **Reports** — charts/summaries of income vs. spending (via `fl_chart`).
- **Export** — pick any set of months (across years) and save the recap as an
  Excel workbook (`.xlsx`) or a Word report (`.docx`). See
  [Exporting finance data](#exporting-finance-data).
- **Insulin** — track insulin items, batch assignments, and dose usage (via
  `health-api`). Can be switched off under Settings → Extra features.
- **Settings** — configure API endpoints, username, theme, density, currency
  format, extra features, and contact info (email/phone/Telegram username).
- **Extra features** — switches for optional sections, defined in
  `lib/core/features.dart` (mirrored by the desktop app's
  `renderer/js/features.js` — keep the ids in sync). Turning **Health /
  Diabetic** off hides the drawer entry, the Home health panel and the insulin
  quick actions, and makes `/insulin*` redirect to Home; nothing is deleted, so
  switching it back on restores everything. The switch is written to
  `SharedPreferences` first, so it works with no API connection, and is then
  saved to your account as a `FEATURE_*` row via `POST /api/user/settings`. A
  change made offline is queued and pushed on the next successful sync; the
  queued value always wins over the older server value.
- **API Watcher** — an in-app log of recent API calls (method, path, status,
  duration, errors) to diagnose connectivity issues, especially on mobile.

## Architecture

- **State management**: Riverpod (`flutter_riverpod`)
- **Routing**: `go_router` (see `lib/app.dart`)
- **Local storage**: `sqflite` (mobile) / `sqflite_common_ffi` (desktop) — the
  app works fully offline against a local SQLite cache (`lib/core/db.dart`)
- **Sync**: `lib/core/sync.dart` (`SyncService`) periodically pushes/pulls
  local changes to/from `transaction-api` (`/api/flutter/sync*`) and
  `health-api` (`/api/flutter/health-sync*`) when online (via `connectivity_plus`)
- **Manual refresh**: the refresh icon in the top bar (next to the sync pill,
  on both the main and the Diabetic shell) pulls straight away instead of
  waiting for the timer — use it to see something entered on another device.
  It runs `AppDataNotifier.refreshFromServer()`, which pushes anything queued
  and then guarantees a remote read: `SyncService.syncNow()` skips its whole
  body when a sync is already in flight, so in that case the refresh does the
  remote read itself rather than appearing to do nothing. The result is
  reported as a snackbar (refreshed / no connection / API unreachable)
- **Remote API client**: `lib/core/remote_api.dart` (`RemoteApi`) — thin REST
  wrapper around `/api/user/{created_by}/...` endpoints, with a 10s request
  timeout and call logging to `lib/core/api_log.dart`
- **Config**: `lib/core/config.dart` (`ConfigService`) — persists `AppConfig`
  (API URLs, username, theme, etc.) via `shared_preferences`

```
lib/
  main.dart        # entrypoint: DB init, config load, seed, sync start
  app.dart         # MaterialApp.router + route table
  core/            # config, db, models, remote_api, sync, repo, api_log,
                    # receipt_scanner (ML Kit OCR), receipt_parser (pure Dart),
                    # export_report/export_xlsx/export_docx/export_service
  screens/         # dashboard, transactions, reports, export, insulin, settings,
                    # source/category detail, add-transaction, scan-receipt,
                    # onboarding, api-log (API Watcher)
  providers/       # Riverpod providers
  theme/           # app theming
```

## Configuration

On first launch, the **onboarding** screen requires a `username` to be set —
this is used as the `created_by` path segment for all `transaction-api` /
`health-api` calls. Until a username is set, the app redirects to `/onboarding`.

All settings are editable later from the **Settings** screen and persisted
locally (`shared_preferences`):

| Setting | Default | Description |
|---|---|---|
| API base URL | `http://127.0.0.1:8080` | Base URL for `transaction-api` (default deployment uses port `3000`) |
| Health API base URL | `http://127.0.0.1:8082` | Base URL for `health-api` (default deployment uses port `4000`) |
| Username | _(empty)_ | Used as `created_by` for all API calls |
| Auto sync | `true` | Periodically sync local cache with the backends |
| Sync interval | `30s` | How often `SyncService` syncs when online |
| Theme | `ink` | UI theme |
| Density | `regular` | UI density |
| Currency format | `full` | Number/currency display format |
| Email / Phone / Telegram username | _(empty)_ | Contact info, used by `telegram-bot` integrations |

> **Running on a physical mobile device**: `127.0.0.1` refers to the device
> itself, not your development machine. Set the API base URLs to your
> machine's LAN IP (e.g. `http://192.168.1.x:3000` and `http://192.168.1.x:4000`),
> ensure both Rust APIs are started with `HOST=0.0.0.0` in their `.env`, and
> that your firewall allows inbound connections on those ports. Use the
> **API Watcher** (Settings → API Watcher) to confirm calls are succeeding.

## Running locally

```bash
flutter pub get
flutter run            # pick a connected device/emulator, or
flutter run -d chrome  # web
flutter run -d windows # desktop
```

Make sure `transaction-api` and `health-api` are running first (see their
READMEs), and that the API base URLs in Settings (or onboarding) point to them.

### Receipt scanner

Flow: **capture → crop → OCR → confirm items → Add transaction**.

1. `ReceiptScanner.pickImage` takes the photo (`image_picker`).
2. `CropReceiptScreen` (`lib/screens/crop_receipt_screen.dart`) shows it with a
   draggable rectangle. Restricting OCR to the item/price columns — leaving out
   the store header and the totals footer — is the biggest single accuracy win.
   The selection is returned as a normalized `Rect` (0..1 image coordinates), so
   it survives rotation and is reused as the starting box next time.
3. `ImageCrop.cropToFile` (`lib/core/image_crop.dart`) cuts the region to a PNG
   in the temp directory using `dart:ui` only — no image-processing dependency.
   A full-frame selection short-circuits and skips the re-encode.
4. `ReceiptScanner.scanFile` runs ML Kit, then `OcrLayout`
   (`lib/core/ocr_layout.dart`) rebuilds reading order from each line's bounding
   box before `ReceiptParser` interprets it. This step is essential: ML Kit's
   `RecognizedText.text` walks whole *blocks*, and on a receipt the item names
   are one block and the prices another — so it reads each column top-to-bottom
   and names never line up with their prices. `OcrLayout` groups lines into
   visual rows (left → right) instead.
5. The review list shows a thumbnail of exactly what was read; **Adjust area &
   rescan** reopens the crop screen on the same photo, so a bad first pass never
   means retaking the picture.

The scanner uses `google_mlkit_text_recognition` (on-device, no API key, no
upload) plus `image_picker`. Both are pinned loosely in `pubspec.yaml`; run
`flutter pub get` — or `flutter pub upgrade google_mlkit_text_recognition` — after
pulling this change.

Platform notes:

- **Android** — needs `minSdk 21` and the `CAMERA` permission (already in
  `AndroidManifest.xml`). ML Kit adds ~15 MB to the APK; use
  `flutter build appbundle` so Play delivers only the needed ABI.
- **iOS** — needs iOS 15.5+ and the `NSCameraUsageDescription` /
  `NSPhotoLibraryUsageDescription` keys (already in `Info.plist`). Run
  `pod install` in `ios/` after `flutter pub get`.
- **Desktop / web** — unsupported by ML Kit, so `ReceiptScanner.isSupported`
  returns `false` and the scan entry points are hidden. Line items can still be
  added by hand on the Add-transaction screen.

Both the layout regrouping (`lib/core/ocr_layout.dart`) and the parsing
heuristics (`lib/core/receipt_parser.dart`) are pure Dart with no plugin
imports, so they are unit-testable on any platform:

```bash
flutter test test/receipt_parser_test.dart test/ocr_layout_test.dart
```

If a scan ever comes back with names and prices mismatched, open **Raw scanned
text** on the review screen — it shows the post-`OcrLayout` text, so a bad pair
is immediately visible as a badly grouped row. `OcrLayout.defaultRowTolerance`
(0.6 of the taller line's height) is the knob to turn if rows are being merged
or split incorrectly.

### Investment prices

`lib/core/metal_price.dart` (`MetalPriceService`) fetches gold and silver in
rupiah per gram. Two different sources, because no free one covers both:

| Metal | Source | Notes |
| --- | --- | --- |
| Gold | [`logam-mulia-api`](https://github.com/iamutaki/logam-mulia-api) | Scrapes Indonesian retailers (Aneka Logam → Pegadaian → Logam Mulia, in that order). Quotes IDR/gram directly and prefers the **buyback** price — what a dealer would actually pay you. Rows are normalised to per-gram and the one closest to 1 gram wins, since small bars carry a bigger fabrication margin. |
| Silver | [`gold-api.com`](https://gold-api.com/) × USD-IDR | That API carries no silver from any source, so silver is derived from global spot (USD/troy ounce) converted via [`open.er-api.com`](https://www.exchangerate-api.com/docs/free), falling back to [`frankfurter.dev`](https://frankfurter.dev/). A market reference, not a dealer quote, so real silver sells for somewhat less. |

All of these are keyless public endpoints, so failures are always soft: a dead
source is skipped and the affected holdings keep the price already stored on
them. Results are cached for 30 minutes (bypassed by **Refresh**), and every
call is recorded in the **API Watcher** so a source that has gone away is
diagnosable on-device.

**Reksa dana has no automatic price.** Indonesia has no free public NAB API —
OJK publishes monthly, and Bibit/Bareksa/Pluang publish nothing — so the
current NAB per unit is typed in from the broker app via **Update NAB** on the
holding's menu. The same menu offers a manual override for metals, and is the
only way an **Others** holding is revalued — no single API could quote crypto,
bonds and stocks alike, so its price per unit is always entered by hand.

### Exporting finance data

**Reports → Export** opens `lib/screens/export_screen.dart` (the only entry
point — it is deliberately not in the drawer, which lists top-level
destinations only): tick any months across any years, choose
Excel or Word, and save. A preview of the selected range (transaction count,
earned/spent/net) updates as you tick.

| File | Contents |
| --- | --- |
| `.xlsx` | **Summary** (per-month earned/spent/net + counts, totals, monthly average) · **By Category** (per-month spending and earning per category with share of month) · **Transactions** (every transaction in range, incl. signed amount and sync state) · **Sources** (balance per source + liquid total) |
| `.docx` | Overview table, monthly recap table, then one section per month (KPIs, spending/earning by category, transaction table), ending with source balances |

Amounts are written as **real numbers** in Excel (number format `#,##0`), so
they can be pivoted and charted; the Word report uses the formatted currency
from Settings. Transfers are listed in the transaction sheet but excluded from
earned/spent totals, matching the Reports screen.

Implementation (`lib/core/`):

- `export_report.dart` — aggregation. Everything is precomputed here, and
  `personal_dashboard_desktop/renderer/js/export.js` is a straight port, so
  both apps produce identical numbers.
- `export_xlsx.dart` / `export_docx.dart` — hand-written OOXML (SpreadsheetML /
  WordprocessingML) zipped with `archive`. No Excel/Word package is used; the
  only new dependency is `archive`.
- `export_service.dart` — on Android/iOS the file goes to the OS share sheet
  (`share_plus`); on Windows/macOS/Linux it is written to the Downloads folder
  (`path_provider`), never overwriting an existing export (`name (2).xlsx`).

Run `flutter pub get` after pulling this change to fetch `archive`.

## Building / Deployment

```bash
# Android
flutter build apk --release
flutter build appbundle --release

# iOS (on macOS)
flutter build ios --release

# Desktop
flutter build windows --release
flutter build linux --release
flutter build macos --release

# Web
flutter build web --release
```

For web builds, the backend APIs must have CORS enabled (already configured
on `transaction-api` via `actix-cors`; see [health-api README](../health-api/README.md#cors-and-logging)
for its current status) and be reachable from the browser's origin.

Deploy the built artifacts (APK/IPA for mobile, the `build/web` output behind
a static file server for web, or the platform executable for desktop) as
appropriate for your distribution channel. Update the API base URLs in
Settings to point at your deployed `transaction-api` / `health-api` instances.
