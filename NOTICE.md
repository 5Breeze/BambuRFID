# BambuRFID — Notices and acknowledgements

BambuRFID is an independent community project.

## BambuRFID

Project repository: https://github.com/5Breeze/BambuRFID

BambuRFID project source code is distributed under the GNU General Public License v3.0. See `LICENSE`.

BambuRFID is a fully open-source, non-commercial project. It is not operated for profit, has no commercial interests, and does not participate in commercial activities.

## Flutter

The application UI is built with the Flutter SDK. Flutter is distributed under its upstream BSD-style license. Flutter itself is not vendored into this repository.

## Android NFC / MIFARE Classic

The Android application uses platform APIs including `android.nfc.NfcAdapter` and `android.nfc.tech.MifareClassic`. These APIs are provided by the Android platform and are not vendored into this repository.

## Bambu Lab RFID research

The RFID data layout and key-derivation implementation were developed with reference to public reverse-engineering research, especially:

- https://github.com/queengooborg/Bambu-Lab-RFID-Tag-Guide
- https://github.com/queengooborg/Bambu-Lab-RFID-Library

The Bambu-Lab-RFID-Library repository identifies its upstream license as GPL-3.0. The tag guide is treated as a research/documentation reference and remains subject to the terms of its upstream repository.

No RFID dump collection is bundled into the application package.

## Trademarks / affiliation

“Bambu Lab” and related names and marks are the property of their respective owners. BambuRFID is not affiliated with, authorized by, sponsored by, or endorsed by Bambu Lab.

## No warranty

BambuRFID is provided without warranty. NFC and MIFARE Classic support differs by Android device and NFC chipset.
