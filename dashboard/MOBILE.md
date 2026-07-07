# Mobile app (Android / iOS)

The dashboard is a single Flutter codebase that runs as the web kiosk **and** as
a native mobile app — same screens, same live SSE, same camera/automation
features. No separate app to maintain.

## What's already wired for mobile

- **`android/`** platform project present; `applicationId = com.pms.plantmonitor`.
- **Cleartext LAN HTTP** allowed (`android:usesCleartextTraffic="true"` in
  `android/app/src/main/AndroidManifest.xml`) so the phone can reach the edge
  server at `http://<edge-ip>:8000` without TLS on the local network.
- **`INTERNET`** permission declared.
- **Native camera** — the "Capture Leaf" button uses `image_picker`, which opens
  the real device camera on Android/iOS (better than the web file-picker path).
- **Credential persistence** — the hub URL + token are saved with
  `shared_preferences` and prefilled on next launch, so you don't retype them on
  every open (there's no kiosk deep-link on mobile).
- **Responsive layout** — header stacks and cards size to one column on phone-
  width screens.

## Build prerequisites (one-time, on a machine with the Android SDK)

This repo's dev machine has Flutter but **no Android SDK**, so the APK must be
built where the SDK is installed:

1. Install Android Studio (bundles the SDK + platform tools).
2. `flutter doctor --android-licenses` and accept.
3. Confirm: `flutter doctor` shows **Android toolchain ✓**.

## Build & run

```bash
cd dashboard
flutter pub get

# Run on a connected phone / emulator (hot reload):
flutter run

# Build a release APK:
flutter build apk --release
# -> build/app/outputs/flutter-apk/app-release.apk  (sideload to the phone)

# (Optional) per-ABI smaller APKs:
flutter build apk --split-per-abi
```

iOS additionally needs macOS + Xcode (`flutter build ipa`); the codebase is
iOS-ready but no `ios/` folder is generated yet — run
`flutter create --platforms=ios .` on a Mac to add it.

## Connecting the phone to the edge server

1. Put the phone on the **same WiFi** as the edge server (Windows dev box /
   Jetson / Pi).
2. Launch the app → enter:
   - **Hub Endpoint:** `http://<edge-ip>:8000` (the server's LAN IP)
   - **Access Token:** the `API_AUTH_TOKEN` (or a per-device token)
3. Tap **Establish Link**. The token is validated against `/nodes`, then saved
   for next time.

> If the connection fails, check the edge host's firewall allows inbound TCP
> 8000 on the private network, and that the phone and server share the subnet.

## Notes

- The login token validation (added this session) means a wrong token is caught
  at the login screen rather than failing silently on the dashboard.
- For a production build, replace the debug signing config in
  `android/app/build.gradle.kts` with a real release keystore.
