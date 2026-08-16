param(
    [string]$DestinationDirectory = (Join-Path $PSScriptRoot '..\artifacts\ffmpeg\bin')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$version = '8.1.2'
$archiveUrl = 'https://github.com/GyanD/codexffmpeg/releases/download/8.1.2/ffmpeg-8.1.2-essentials_build.zip'
$expectedSHA256 = 'db580001caa24ac104c8cb856cd113a87b0a443f7bdf47d8c12b1d740584a2ec'
$destination = [System.IO.Path]::GetFullPath($DestinationDirectory)
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "hlsdownloader-ffmpeg-$([Guid]::NewGuid().ToString('N'))"
$archivePath = Join-Path $temporaryRoot 'ffmpeg.zip'
$extractPath = Join-Path $temporaryRoot 'extracted'

try {
    New-Item -ItemType Directory -Force -Path $temporaryRoot, $extractPath, $destination | Out-Null

    $downloaded = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath -UseBasicParsing
            $downloaded = $true
            break
        }
        catch {
            Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
            if ($attempt -eq 3) {
                throw
            }

            Start-Sleep -Seconds (5 * $attempt)
        }
    }

    if (-not $downloaded) {
        throw "FFmpeg $version could not be downloaded."
    }

    $actualSHA256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSHA256 -ne $expectedSHA256) {
        throw "FFmpeg archive checksum mismatch. Expected $expectedSHA256, got $actualSHA256."
    }

    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath
    $ffmpeg = Get-ChildItem -LiteralPath $extractPath -Filter 'ffmpeg.exe' -File -Recurse |
        Where-Object { $_.Directory.Name -eq 'bin' } |
        Select-Object -First 1
    $ffprobe = Get-ChildItem -LiteralPath $extractPath -Filter 'ffprobe.exe' -File -Recurse |
        Where-Object { $_.Directory.Name -eq 'bin' } |
        Select-Object -First 1
    if (-not $ffmpeg -or -not $ffprobe) {
        throw 'The verified FFmpeg archive did not contain ffmpeg.exe and ffprobe.exe.'
    }

    Copy-Item -LiteralPath $ffmpeg.FullName -Destination (Join-Path $destination 'ffmpeg.exe') -Force
    Copy-Item -LiteralPath $ffprobe.FullName -Destination (Join-Path $destination 'ffprobe.exe') -Force

    $ffmpegVersion = & (Join-Path $destination 'ffmpeg.exe') -version | Select-Object -First 1
    $ffprobeVersion = & (Join-Path $destination 'ffprobe.exe') -version | Select-Object -First 1
    if ($ffmpegVersion -notmatch '^ffmpeg version 8\.1\.2-essentials_build-www\.gyan\.dev(?:\s|$)' -or
        $ffprobeVersion -notmatch '^ffprobe version 8\.1\.2-essentials_build-www\.gyan\.dev(?:\s|$)') {
        throw "The extracted tools do not report FFmpeg $version."
    }

    if ($env:GITHUB_PATH) {
        Add-Content -LiteralPath $env:GITHUB_PATH -Value $destination -Encoding utf8
    }

    Write-Host $ffmpegVersion
    Write-Host $ffprobeVersion
    Write-Output $destination
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
