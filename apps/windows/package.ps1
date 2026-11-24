$ErrorActionPreference = 'Stop'
Set-Location "$PSScriptRoot/../.."

function Invoke-Checked {
    param([scriptblock]$Command)
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $Command" }
}

function Get-VerifiedFile {
    param([string]$Url, [string]$Destination, [string]$Sha256)
    Invoke-Checked { curl.exe -fLsS --retry 3 --connect-timeout 15 --max-time 180 $Url -o $Destination }
    if ((Get-FileHash $Destination -Algorithm SHA256).Hash -ne $Sha256) {
        throw "Checksum mismatch for $Destination"
    }
}

$repo = (Get-Location).Path
$stage = Join-Path $repo 'apps/windows/build/package'
$bundle = Join-Path $stage 'BRB Tracker'
$tmp = Join-Path $env:RUNNER_TEMP 'brb-windows-tools'
$null = New-Item -Force -ItemType Directory $bundle, $tmp

Invoke-Checked { python -m pip install -e '.[dev]' 'pyinstaller>=6.15,<7' }
Invoke-Checked { python -m pytest -q tests/test_windows_download.py }
Push-Location 'apps/windows'
try {
    Invoke-Checked { flutter pub get --enforce-lockfile }
    Invoke-Checked { flutter analyze --no-pub }
    Invoke-Checked { flutter test --no-pub }
    Invoke-Checked { flutter build windows --release --no-pub }
} finally {
    Pop-Location
}

Copy-Item 'apps/windows/build/windows/x64/runner/Release/*' $bundle -Recurse -Force
# Supply the native runtime alongside the executable for a portable installation.
$vs = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$install = & $vs -latest -products '*' -property installationPath
$crt = Get-Item "$install/VC/Redist/MSVC/*/x64/Microsoft.VC143.CRT" |
    Sort-Object { [version]$_.Parent.Parent.Name } -Descending |
    Select-Object -First 1
if (!$crt) { throw 'Visual C++ runtime not found' }
Copy-Item "$($crt.FullName)/*.dll" $bundle

Invoke-Checked {
    python -m PyInstaller --noconfirm --onedir --name brb-worker --collect-all yt_dlp --collect-all yt_dlp_ejs --recursive-copy-metadata brb-tracker `
        --distpath $tmp --workpath "$tmp/work" --specpath $tmp apps/windows/worker.py
}
Copy-Item "$tmp/brb-worker" "$bundle/worker" -Recurse

$tools = Join-Path $bundle 'tools'
$null = New-Item -ItemType Directory "$tools/tessdata"
Get-VerifiedFile `
    'https://github.com/FFmpeg-Builds/FFmpeg-Builds/releases/download/autobuild-2026-11-24-12-41/ffmpeg-n8.1.3-41-ga8029b6528-win64-gpl-8.1.zip' `
    "$tmp/ffmpeg.zip" 'a6bd440aa135a628da65dc4338e86761420ddb7b5f5839d08f31a79c9dc405d7'
Expand-Archive "$tmp/ffmpeg.zip" "$tmp/ffmpeg"
$ffmpeg = Get-ChildItem "$tmp/ffmpeg" -Directory | Select-Object -First 1
Copy-Item "$($ffmpeg.FullName)/bin/ffmpeg.exe", "$($ffmpeg.FullName)/bin/ffprobe.exe" $tools
Copy-Item "$($ffmpeg.FullName)/LICENSE.txt" "$tools/FFmpeg-LICENSE.txt"

Get-VerifiedFile `
    'https://github.com/denoland/deno/releases/download/v2.9.8/deno-x86_64-pc-windows-msvc.zip' `
    "$tmp/deno.zip" 'cba84b26e0df5ae7f74fc66b86a95b866872a86292ebd84fa1e959927edd93bf'
Expand-Archive "$tmp/deno.zip" "$tmp/deno"
Copy-Item "$tmp/deno/deno.exe" $tools

Get-VerifiedFile `
    'https://github.com/UB-Mannheim/tesseract/releases/download/v5.4.0.20240606/tesseract-ocr-w64-setup-5.4.0.20240606.exe' `
    "$tmp/tesseract-setup.exe" 'c885fff6998e0608ba4bb8ab51436e1c6775c2bafc2559a19b423e18678b60c9'
$installer = Start-Process "$tmp/tesseract-setup.exe" -ArgumentList "/S /D=$tmp\tesseract" -Wait -PassThru
if ($installer.ExitCode -ne 0) { throw "Tesseract setup failed with code $($installer.ExitCode)" }
Copy-Item "$tmp/tesseract/*.dll", "$tmp/tesseract/tesseract.exe" $tools
Copy-Item 'apps/mobile/android/app/src/main/assets/tessdata/eng.traineddata' "$tools/tessdata"
Copy-Item 'apps/windows/README.md', 'apps/windows/THIRD_PARTY_NOTICES.txt', 'apps/mobile/LICENSE' $bundle

$fixture = Join-Path $repo 'apps/mobile/android/app/src/androidTest/assets/synthetic.mp4'
$result = Join-Path $tmp 'smoke scan'
$worker = Join-Path $bundle 'worker/brb-worker.exe'
Invoke-Checked { & $worker --runtime $tools --self-test }
Invoke-Checked { & $worker --runtime $tools --video $fixture --output $result --profile full_frame --limit-mbps 5 }
$report = Get-Content "$result/report.json" -Raw | ConvertFrom-Json
if ($report.breaks.Count -lt 1 -or $report.schema_version -ne 1) { throw 'Windows scan smoke test found no breaks' }

$exe = Start-Process "$bundle/brb_tracker_windows.exe" -PassThru
try {
    Start-Sleep -Seconds 5
    if ($exe.HasExited) { throw 'The packaged desktop app failed to start' }
} finally {
    if (!$exe.HasExited) { Stop-Process -Id $exe.Id }
}

$archive = Join-Path $stage 'BRB-Tracker-Windows-x64.zip'
$zip = Join-Path $env:ProgramFiles '7-Zip/7z.exe'
Invoke-Checked { & $zip a -tzip -mx=3 $archive $bundle }
$hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  BRB-Tracker-Windows-x64.zip" | Set-Content "$archive.sha256" -Encoding ascii
