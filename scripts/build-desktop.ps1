param(
  [ValidateSet('Debug','Release')]
  [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'

Write-Host "Building Windows agent ($Configuration)..."

$sdks = & dotnet --list-sdks 2>$null
if (-not $sdks) {
  throw "No .NET SDK found. Install .NET SDK 8.x from https://dotnet.microsoft.com/download"
}

Push-Location (Join-Path $PSScriptRoot '..\desktop\Pconnect.Agent')
try {
  dotnet publish -c $Configuration -r win-x64 /p:PublishSingleFile=true /p:SelfContained=true
  Write-Host "Publish complete."
} finally {
  Pop-Location
}
