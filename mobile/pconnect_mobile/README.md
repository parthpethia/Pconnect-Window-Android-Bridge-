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
