# Universal Print

Android app that receives print jobs from other software (POS, ERP, web apps)
and prints directly — no preview — to thermal/POS printers over Bluetooth or
Wi-Fi/LAN. See `txt` for the full roadmap.

## MVP status (v1.0)

| Feature | Status |
|---|---|
| Bluetooth Classic (SPP) printers | ✅ native Kotlin bridge, socket cached + auto reconnect |
| Wi-Fi / LAN printers (raw TCP 9100) | ✅ |
| ESC/POS: text, bold, size, align, rows, separator, cut, cash drawer | ✅ |
| Barcode (CODE128), QR (native) | ✅ |
| Images (PNG/JPEG, dithered) | ✅ |
| Bangla / any Unicode text (rendered as raster) | ✅ |
| 58 mm / 80 mm paper | ✅ |
| Default printer, print queue, history, retry, duplicate prevention | ✅ |
| Local HTTP API with token auth | ✅ |
| Pairing (per-software tokens, approve in app) | ✅ |
| Routes: print type → printer, synced from software | ✅ |
| Paper width per printer / route / job, geometry exposed to software | ✅ |
| Batch printing (invoice + kitchen + bar in one call) | ✅ |
| Background service (API alive when app is closed) | ⏳ next |
| Android Intent integration | ⏳ next |
| USB OTG, A4 / PDF (IPP), label (ZPL/TSPL) | ⏳ v2 |

## Project layout

```
lib/
  core/escpos/        ESC/POS builder, document renderer, rasterizer (Bangla, images)
  core/connection/    Bluetooth bridge + TCP connection
  data/               SQLite (sqflite) models and repositories
  services/           printer store, clients & routes, print queue, local API server
  ui/                 screens
android/app/src/main/kotlin/.../BluetoothBridge.kt   Bluetooth SPP
```

## Run

```bash
flutter pub get
flutter test
flutter run            # on a real Android phone (Bluetooth needs real hardware)
```

1. Pair the printer in Android Bluetooth settings (or note its IP for Wi-Fi).
2. Printers → Add printer → choose device / enter IP → Test print.
3. Connect software: it pairs itself with `POST /api/pair` (approve it in the
   app), or copy the master token from the **Connect** tab.

## Build

Requirements: Flutter 3.47+ (Dart 3.13+), Android SDK, Java 17.

```bash
flutter clean && flutter pub get    # fresh build

flutter analyze                     # static checks
flutter test                        # unit + API flow tests

# Debug APK (for testing)
flutter build apk --debug
# → build/app/outputs/flutter-apk/app-debug.apk

# Release APK, one per CPU architecture (smaller files)
flutter build apk --release --split-per-abi
# → build/app/outputs/flutter-apk/app-arm64-v8a-release.apk   (most phones)
#   build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk (old 32-bit phones)

# Release APK, single universal file (all architectures)
flutter build apk --release

# Play Store bundle
flutter build appbundle --release
# → build/app/outputs/bundle/release/app-release.aab
```

Install on a connected phone (USB debugging on):

```bash
adb devices                                                        # phone must be listed
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

> **Signing:** release builds are currently signed with the debug key (see
> `android/app/build.gradle.kts`). That is fine for in-house installs, but the
> Play Store needs your own keystore. Set it up before publishing; see
> https://docs.flutter.dev/deployment/android#sign-the-app.

## Integration API

Full reference for software developers: **[docs/API.md](docs/API.md)**

In short: pair once (`POST /api/pair`, user taps *Allow*), declare your print
types (`PUT /api/routes`), let the user pick a printer per route in the app,
then print with `POST /api/print {"route": "kitchen", ...}`.
