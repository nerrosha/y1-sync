# End-to-end check of the JSON commands on real files, on a Windows machine:
# builds a tiny library with ffmpeg, "syncs" it to a folder standing in for the
# player, and checks the result. Run from the repository root after `swift build`.
$ErrorActionPreference = "Stop"
$bin = (swift build --show-bin-path).Trim()
$exe = Join-Path $bin "y1sync.exe"
$tmp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$lib = Join-Path $tmp "smoke-lib"; $dev = Join-Path $tmp "smoke-dev"; $data = Join-Path $tmp "smoke-data"
Remove-Item -Recurse -Force $lib, $dev, $data -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$lib\Band\Album", $dev | Out-Null
$env:Y1SYNC_DATA = $data

foreach ($n in 1..3) {
    ffmpeg -v error -f lavfi -i "sine=frequency=$(300 + $n * 50):duration=12" `
        -metadata title="Song $n" -metadata artist="Band" -metadata album="Album" -metadata track="$n" `
        "$lib\Band\Album\track$n.flac"
}

function Call([hashtable]$request) {
    $lines = ($request | ConvertTo-Json -Compress -Depth 6) | & $exe api
    $last = $lines | Select-Object -Last 1
    $obj = $last | ConvertFrom-Json
    if (-not $obj.ok) { throw "$($request.cmd) failed: $($obj.error)" }
    return $obj.data
}
function Check($ok, $what) {
    if ($ok) { Write-Host "ok   $what" } else { throw "FAILED: $what" }
}

$ping = Call @{ cmd = "ping" }
Check ($ping.ffmpeg -eq $true) "ffmpeg found"

$null = Call @{ cmd = "settings.set"; patch = @{ libraryFolder = $lib; devicePath = $dev } }
$plan = Call @{ cmd = "plan" }
Write-Host "plan: $($plan.stats | ConvertTo-Json -Compress)"
Check ($plan.stats.toCopy -eq 3) "plan finds 3 files to copy"
Check ($plan.stats.broken -eq 0) "no broken files"

$sync = Call @{ cmd = "sync" }
Write-Host $sync.summary
Check ($sync.copied -eq 3) "sync copied 3 files"
Check ($sync.verified -eq 3) "all 3 verified by reading back"
Check ((Get-ChildItem -Recurse -File "$dev\Music" -Filter *.flac).Count -eq 3) "3 files on the player"

$again = Call @{ cmd = "plan" }
Check ($again.stats.toCopy -eq 0) "second plan has nothing to copy"

$scan = Call @{ cmd = "device.scan" }
Check ($scan.trackCount -eq 3) "device scan sees 3 tracks"
Check ($scan.formats.Count -ge 1) "formats listed"
Write-Host "ALL GOOD"
