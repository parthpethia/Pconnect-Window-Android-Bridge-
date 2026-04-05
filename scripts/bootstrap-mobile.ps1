$ErrorActionPreference = 'Stop'

Write-Host "Bootstrapping Flutter project under mobile/pconnect_mobile..."

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
  throw "Flutter is not installed. See https://docs.flutter.dev/get-started/install"
}

Push-Location (Join-Path $PSScriptRoot '..\mobile')
try {
  if (-not (Test-Path .\pconnect_mobile\pubspec.yaml)) {
    flutter create pconnect_mobile
  }

  Push-Location .\pconnect_mobile
  try {
    flutter pub get
    Write-Host "OK. Next: flutter run OR flutter build apk --release"
  } finally {
    Pop-Location
  }
} finally {
  Pop-Location
}
