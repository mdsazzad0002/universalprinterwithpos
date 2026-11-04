# Universal Print

Android, Linux and Windows app that receives print jobs from other software (POS, ERP, web apps)
and prints directly — no preview — to thermal/POS printers over Bluetooth,
Wi-Fi/LAN or USB. See `txt` for the full roadmap.

## MVP status (v1.0)

| Feature | Status |
|---|---|
| Bluetooth Classic (SPP) printers | ✅ Android: native Kotlin bridge, socket cached + auto reconnect · Linux: BlueZ + RFCOMM |
| USB printers | ✅ Android: USB OTG (Kotlin USB Host API) · Linux: `/dev/usb/lp*` |
| Linux desktop app | ✅ Wi-Fi/LAN, USB, Bluetooth (BlueZ), same API |
| Windows desktop app | ✅ Wi-Fi/LAN, installed printers (USB, RAW spooler), Bluetooth (COM port), same API |
| API token optional for same-device software | ✅ |
| Wi-Fi / LAN printers (raw TCP 9100) | ✅ |
| ESC/POS: text, bold, size, align, rows, separator, cut, cash drawer | ✅ |
| Cash drawer per printer: open on cash payments / every receipt, `open_drawer`, `POST /api/drawer` | ✅ |
| Label printers (TSPL: TSC, Xprinter label, HPRT, TD-series), 203/300 dpi, label width × height | ✅ |
| Live print feedback in the app (Printing… → printed / error + Retry) | ✅ |
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
| Background service (API alive when app is closed, starts at boot) | ✅ Android: foreground service, Menu → *Run in background* |
| Android Intent integration (`action.PRINT`, Share → Universal Print) | ✅ see [docs/API.md](docs/API.md#android-intent-no-http) |
| Zebra / ZPL label printers | ✅ same elements as TSPL, 203/300 dpi |
| A4 / PDF (IPP, CUPS queues) | ✅ `document_type: "pdf"` to printers of type *A4 / PDF (IPP)* |
| Software picks the printer per print type over the API (`GET /api/printers`, `PUT /api/routes` + `printer_id`) | ✅ nothing to set in the app |

## Project layout

```
lib/
  core/escpos/        ESC/POS builder, document renderer, rasterizer (Bangla, images)
  core/connection/    Bluetooth, USB, TCP, IPP (A4 PDF), Windows spooler
  core/tspl/, zpl/    label printer renderers
  core/pdf/           test page for A4 printers
  data/               SQLite (sqflite) models and repositories
  core/ipp/, raster/  IPP server codec + HTTP, PWG / Apple raster decoder
  services/           printer store, clients & routes, print queue, local API server,
                      system_printer.dart (driverless IPP printer), os_printer_setup.dart
  ui/                 screens
android/app/src/main/kotlin/.../BluetoothBridge.kt   Bluetooth SPP
android/app/src/main/kotlin/.../UsbBridge.kt         USB OTG
android/app/src/main/kotlin/.../PrintEngine.kt       shared Flutter engine (UI, service, intents)
android/app/src/main/kotlin/.../PrintForegroundService.kt  background API
android/app/src/main/kotlin/.../PrintIntentActivity.kt     print from other apps
android/app/src/main/kotlin/.../UniversalPrintService.kt   Android system printer (print dialog)
linux/                                                Linux desktop runner
windows/                                              Windows desktop runner
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

Requirements: Flutter 3.47+ (Dart 3.13+). Android: Android SDK, Java 17.
Linux: see [Linux](#linux) below. Windows: see [Windows](#windows) below.

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

## Linux

### Build requirements (one time)

```bash
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libsqlite3-dev
flutter config --enable-linux-desktop
```

### Build and run

```bash
flutter run -d linux                  # debug, hot reload

flutter build linux --release
# → build/linux/x64/release/bundle/universal_print   (run this file)

./build/linux/x64/release/bundle/universal_print
```

To install it on another PC, copy the **whole `bundle/` folder**, not just the
binary, because the `lib/` and `data/` folders next to it are required.

```bash
tar -czf universal_print-linux-x64.tar.gz -C build/linux/x64/release bundle
```

The target PC needs `libgtk-3-0`, `libsqlite3-0`, and a Bangla font for Bangla
receipts (`sudo apt install fonts-noto-core` or `fonts-beng`).

### USB printer permission

USB printers appear as `/dev/usb/lp0`, `/dev/usb/lp1`, … and belong to the
`lp` group, so by default the app gets *"No permission for /dev/usb/lp0"*. Fix it
once with **one** of these:

```bash
# A) recommended: works immediately, no logout
sudo ./linux/setup-usb-permission.sh

# B) or join the lp group, then log out and back in
sudo usermod -aG lp $USER
```

Check with `ls -l /dev/usb/`. When you pick a USB printer, the app reads its
IEEE 1284 ID and **auto-detects** whether it is a receipt (ESC/POS) or label
(TSPL) printer, and its dpi.

### Bluetooth on Linux

Pair the printer in the system Bluetooth settings first. The app then lists
paired devices through BlueZ and prints over RFCOMM channel 1, which almost
every SPP printer uses. BlueZ must be running:

```bash
sudo systemctl enable --now bluetooth
```

### Notes

- Data is stored in `~/.local/share/universal_print/universal_print.db`.
- The app prefers X11/XWayland, because GTK 3 on some new GNOME versions
  crashes on Wayland. Force Wayland with `GDK_BACKEND=wayland` if you want it.

## Windows

### Build requirements (one time)

Windows builds must be made **on a Windows PC** (Flutter cannot cross-compile
from Linux). Install:

1. **Flutter 3.47+**, e.g. into `D:\flutter`, and add `D:\flutter\bin` to the
   user `PATH`:

   ```powershell
   git clone --depth 1 -b 3.47.8 https://github.com/flutter/flutter.git D:\flutter
   ```

   Open a **new** terminal afterwards. A terminal that was already open does
   not see the new `PATH` (`flutter: command not found`).

2. **Visual Studio 2022 Build Tools** with the C++ workload (the full Visual
   Studio with *Desktop development with C++* also works; VS Code does not):

   ```powershell
   winget install -e --id Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
   ```

3. **Developer Mode** on: *Settings → Privacy & security → For developers →
   Developer Mode* (or `start ms-settings:developers`). Without it the build
   fails with *"Building with plugins requires symlink support"*.

4. **Inno Setup 6**, only needed to build the installer:

   ```powershell
   winget install -e --id JRSoftware.InnoSetup
   ```

Then check:

```powershell
flutter config --enable-windows-desktop
flutter doctor            # "Visual Studio" must show a green tick
```

### Build and run

```powershell
flutter run -d windows                # debug, hot reload

flutter pub get
flutter build windows --release
# → build\windows\x64\runner\Release\universal_print.exe
```

The `.exe` alone does not run: it needs the `.dll` files and the `data\`
folder next to it. The Visual C++ runtime DLLs (`msvcp140.dll`,
`vcruntime140*.dll`) are copied into `Release\` by `windows/CMakeLists.txt`,
so the target PC does **not** need the VC++ Redistributable.

### Installer (setup.exe)

After `flutter build windows --release`:

**Git Bash** (VS Code's default terminal here):

```bash
"$LOCALAPPDATA/Programs/Inno Setup 6/ISCC.exe" //DAppVersion=1.0.0 windows/installer/universal_print.iss
```

**PowerShell**:

```powershell
& "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" /DAppVersion=1.0.0 windows\installer\universal_print.iss
```

**cmd**:

```bat
"%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe" /DAppVersion=1.0.0 windows\installer\universal_print.iss
```

Output: `build\installer\universal_print-setup-1.0.0-x64.exe`. In Git Bash the
option is written `//DAppVersion` (a single `/` is turned into a path). If Inno
Setup was installed for all users, the path is
`C:\Program Files (x86)\Inno Setup 6\ISCC.exe`.

The installer ([windows/installer/universal_print.iss](windows/installer/universal_print.iss)):

- installs per user without admin rights (admins can choose *all users*),
- adds a Start menu shortcut, an optional desktop icon, and starts the app,
- on uninstall stops the background app and removes its *start at login*
  entry. Data in `%APPDATA%\universal_print` is kept.

It is not code-signed, so Windows SmartScreen may show *"Windows protected your
PC"*. Click *More info → Run anyway*.

### Portable zip (no installer)

```powershell
Compress-Archive build\windows\x64\runner\Release\* universal_print-windows-x64.zip
```

Unzip anywhere on the target PC and run `universal_print.exe`.

### Troubleshooting

| Problem | Fix |
|---|---|
| `flutter: command not found` | Open a new terminal after adding Flutter to `PATH`. |
| *Building with plugins requires symlink support* | Turn on Developer Mode (see above). |
| *Unable to find suitable Visual Studio toolchain* | Install the VS 2022 Build Tools C++ workload; check `flutter doctor`. |
| App installs but does not open on another PC | Rebuild with the current `windows/CMakeLists.txt` (bundles the VC++ DLLs). The target must be 64-bit Windows 10/11. |

### Printers on Windows

| Type | How to set it up |
|---|---|
| Wi-Fi / LAN | Same as other platforms: enter the IP, port 9100. |
| USB | Install the printer in Windows first (vendor driver, or **Generic / Text Only** on its `USB00x` port). In the app choose **USB** → pick the printer by its Windows name. Data is sent as a RAW job, so ESC/POS and TSPL commands reach the printer untouched. Any installed printer (also network or COM) can be picked here. |
| Bluetooth | Pair the printer in Windows Bluetooth settings. Then open *More Bluetooth settings → COM Ports* and make sure it has an **Outgoing** port (e.g. `COM5`). In the app choose **Bluetooth** → pick that COM port. |

### Notes

- Data is stored in `%APPDATA%\universal_print\universal_print.db`.
- When **Allow other devices on Wi-Fi** is turned on, Windows Firewall asks
  once whether to allow the app. Allow it on *Private networks*.

## Integration API

Full reference for software developers: **[docs/API.md](docs/API.md)**

In short: pair once (`POST /api/pair`, user taps *Allow*), declare your print
types (`PUT /api/routes`), let the user pick a printer per route in the app,
then print with `POST /api/print {"route": "kitchen", ...}`.
