# Pconnect Mobile (Flutter)

This folder contains the Flutter app source files that implement discovery + WebSocket control.

## Bootstrap

Because Flutter isn’t installed in this environment, the repo stores only the _author code_.

To generate the full platform folders (android/ etc) on your machine:

```powershell
cd mobile
flutter create pconnect_mobile
# overwrite generated pubspec.yaml and lib/main.dart with the versions from this repo
cd pconnect_mobile
flutter pub get
flutter run
```

## Notes

- Discovery uses UDP broadcast on port `47822`.
- Control uses WebSocket on port `47821` (`/ws`).

## Troubleshooting (Gradle daemon disappeared / hs_err_pid\*.log)

If `flutter build apk --release` fails with **"Gradle build daemon disappeared unexpectedly"** and points to an `hs_err_pid*.log`, the Gradle JVM ran out of **native/commit** memory.

Try:

- Close memory-heavy apps (Android Studio, Chrome tabs, emulators) and retry.
- Ensure Windows has a pagefile enabled (system-managed is fine).
- This repo already reduces Gradle memory usage in `android/gradle.properties`; if you still hit it, lower `org.gradle.jvmargs` further (smaller `-Xmx`) or reduce `org.gradle.workers.max`.
