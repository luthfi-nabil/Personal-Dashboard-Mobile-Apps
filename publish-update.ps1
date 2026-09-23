# Builds the Android APK and publishes it to the local update server
# (the `desktop-updates` container, http://<this machine>:3054/android/).
#
#   .\publish-update.ps1                        # 1.0.0+1 -> 1.0.0+2
#   .\publish-update.ps1 -Bump patch            # 1.0.0+1 -> 1.0.1+2 (also minor/major)
#   .\publish-update.ps1 -Notes "Groups on desktop"
#
# The build number (versionCode) always goes up - Android only installs an
# update whose versionCode is higher than the installed one. Phones running
# the app find the release after their next sync, download it, and show
# "Install" (Android always asks the user to confirm).
#
# Build on this machine: the release APK is signed with this PC's debug key,
# and Android refuses an update signed with a different key than the
# installed app ("App not installed").
param(
    [ValidateSet('none', 'patch', 'minor', 'major')]
    [string]$Bump = 'none',
    [string]$Notes = '',
    # APKs older than this many versions are deleted from releases/.
    [int]$Keep = 2
)

$ErrorActionPreference = 'Stop'
$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $AppDir
$Releases = Join-Path $AppDir 'releases'
$Pubspec = Join-Path $AppDir 'pubspec.yaml'
$Utf8 = New-Object System.Text.UTF8Encoding($false)

# ── Version bump in pubspec.yaml ────────────────────────────────────────────
$text = [IO.File]::ReadAllText($Pubspec)
$m = [regex]::Match($text, '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$')
if (-not $m.Success) { throw 'pubspec.yaml has no "version: x.y.z+n" line' }
$major = [int]$m.Groups[1].Value; $minor = [int]$m.Groups[2].Value
$patch = [int]$m.Groups[3].Value; $build = [int]$m.Groups[4].Value + 1
switch ($Bump) {
    'major' { $major++; $minor = 0; $patch = 0 }
    'minor' { $minor++; $patch = 0 }
    'patch' { $patch++ }
}
$Version = "$major.$minor.$patch"
$text = $text.Remove($m.Index, $m.Length).Insert($m.Index, "version: $Version+$build")
[IO.File]::WriteAllText($Pubspec, $text, $Utf8)
Write-Host "Building Personal Dashboard $Version ($build)..."

# ── Build ───────────────────────────────────────────────────────────────────
# Flutter/Gradle log on stderr, which Windows PowerShell 5.1 turns into errors
# under 'Stop', so run through cmd and judge by exit code.
Push-Location $AppDir
$ErrorActionPreference = 'Continue'
try {
    cmd /c "flutter build apk --release 2>&1" | Select-Object -Last 5
    $code = $LASTEXITCODE
} finally {
    $ErrorActionPreference = 'Stop'
    Pop-Location
}
if ($code -ne 0) { throw "flutter build apk failed (exit $code); pubspec.yaml already says $Version+$build" }

# ── Publish ─────────────────────────────────────────────────────────────────
$Built = Join-Path $AppDir 'build\app\outputs\flutter-apk\app-release.apk'
$ApkName = "personal-dashboard-$Version-$build.apk"
New-Item -ItemType Directory -Force $Releases | Out-Null
Copy-Item -LiteralPath $Built -Destination (Join-Path $Releases $ApkName) -Force
$apk = Get-Item (Join-Path $Releases $ApkName)
$hash = (Get-FileHash $apk.FullName -Algorithm SHA256).Hash.ToLower()

# APK first, manifest last, so a phone never reads a version.json pointing at
# a file that is not there yet.
$manifest = [ordered]@{
    version     = $Version
    build       = $build
    apk         = $ApkName
    sha256      = $hash
    size        = $apk.Length
    notes       = $Notes
    releaseDate = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $Releases 'version.json'), $manifest, $Utf8)

Get-ChildItem $Releases -Filter 'personal-dashboard-*.apk' |
    Sort-Object { [int]($_.BaseName -replace '^.*-', '') } -Descending |
    Select-Object -Skip $Keep |
    Remove-Item -Force

Push-Location $RootDir
$ErrorActionPreference = 'Continue'
try {
    $out = cmd /c "docker compose up -d desktop-updates 2>&1"
    if ($LASTEXITCODE -ne 0) { Write-Warning "Could not start the desktop-updates container:`n$out" }
} finally {
    $ErrorActionPreference = 'Stop'
    Pop-Location
}

Write-Host "Published $Version ($build) to $Releases (served on port 3054 under /android/)."
