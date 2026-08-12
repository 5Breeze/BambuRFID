<p align="center">
  <img src="image/icon.png" alt="BambuRFID" width="120">
</p>

# BambuRFID

BambuRFID is a minimal Flutter app for Android only. It reads compatible Bambu Lab filament RFID tags via the phone's NFC and displays filament information directly.

<p align="center">
  <img src="image/main.jpg" alt="BambuRFID main screen" width="560">
</p>

## Features

- **Scan-and-show**: switching to the current filament immediately once a tag is scanned, no extra button required.
- **Bilingual**: follows the device language on first launch; the manual selection is persisted via Android `SharedPreferences`.
- **Minimal UI**: pure-white single-page design, no stacked cards, no gradients, no glassmorphism; the core layout always fits within one screen.
- **Filament info**: color name with `#RRGGBB` (two hex values for dual-color tags), diameter, nozzle temperature range, drying parameters, weight and production date.
- **Dynamic spool art**: a two-layer structure with a transparent fixed spool layer and a dynamically colorizable filament luminance layer.

## RFID Implementation

The Android native layer lives in `android/app/src/main/kotlin/com/bamburfid/app/MainActivity.kt`. The main flow:

1. Continuously listen for NFC-A tags via `NfcAdapter.enableReaderMode`.
2. Access compatible tags using the Android `MifareClassic` API.
3. Derive sector Key A / Key B from the 4-byte UID using the HKDF-SHA256 method from public research.
4. Authenticate and read the first 5 sectors, then parse material, color, weight, diameter, production date, nozzle temperature and drying parameters.
5. A single-threaded latest-tag queue handles continuous scanning; failed reads are retried automatically, and ReaderMode is refreshed periodically to reduce the chance of the NFC stack entering a stale state.
6. Push results to the Dart UI through a Flutter `EventChannel`.

> An Android phone with NFC does not necessarily support MIFARE Classic. Actual support depends on the NFC controller and the vendor implementation.

## Language Persistence

The project does not depend on any extra Flutter preference plugin:

- On first launch, Dart determines the device language via `platformDispatcher.locale.languageCode`.
- The Android native layer stores `zh` / `en` in `SharedPreferences`; subsequent launches prefer the user's selection.

## Filament Artwork

| Asset | Path |
| --- | --- |
| Fixed spool layer | `assets/spool_base.png` |
| Filament luminance layer | `assets/spool_color_luma.png` |
| Original reference | `tool/reference/spool_reference.png` |
| Recut script | `tool/build_spool_assets.py` |

The recut script is only used to regenerate image assets and is not part of the App build. Running it requires Python, Pillow, NumPy and OpenCV.

## Build

Requirements: Flutter SDK, Android SDK, JDK 17+.

```bash
cd BambuRFID
flutter pub get
flutter build apk --release
```

For development:

```bash
flutter run
```

The APK is typically output to `build/app/outputs/flutter-apk/app-release.apk`.

### Gradle download behind a restricted network

The project ships with `android/gradlew`, `android/gradlew.bat` and `android/gradle/wrapper/`. If `services.gradle.org` redirects to GitHub and the download fails, use the script at the project root:

```bash
chmod +x fix_gradle_local.sh
./fix_gradle_local.sh /path/to/BambuRFID
```

Alternatively, configure a local HTTP proxy for the terminal / Gradle and build directly.

### Release signing

The current `release` build still uses debug signing for easy local APK generation. Before an official release, replace it with your own release keystore configuration in `android/app/build.gradle.kts`.

## Open Source Statement

BambuRFID is a fully open-source, non-commercial project. It does not aim for profit, involves no commercial interests, and does not participate in commercial activities.

Main references:

- [`queengooborg/Bambu-Lab-RFID-Tag-Guide`](https://github.com/queengooborg/Bambu-Lab-RFID-Tag-Guide): RFID data structure, reading method and key derivation research.
- [`queengooborg/Bambu-Lab-RFID-Library`](https://github.com/queengooborg/Bambu-Lab-RFID-Library): tag sample data and field validation reference (upstream licensed under GPL-3.0).
- Flutter SDK: UI framework.
- Android NFC / `MifareClassic`: native NFC access.

See [`NOTICE.md`](NOTICE.md) and [`LICENSE`](LICENSE) for details.

## License

The BambuRFID project code is released under GNU GPL v3.0; see `LICENSE` for the full text.

"Bambu Lab" and related trademarks belong to their respective owners. This project is an independent community tool and is not affiliated with, authorized by, or endorsed by Bambu Lab.
