param(
    [Parameter(Mandatory = $true)]
    [string]$PublishDirectory
)

$ErrorActionPreference = 'Stop'
$publish = (Resolve-Path -LiteralPath $PublishDirectory).Path
$requiredFiles = @(
    'HLSDownloader.Windows.exe',
    'HLSDownloader.Windows.pri',
    'App.xbf',
    'MainWindow.xbf',
    'MediaPlaybackWindow.xbf',
    'PlaybackProbeWindow.xbf',
    'worker\HLSDownloader.Worker.exe',
    'tools\ffmpeg\ffmpeg.exe',
    'tools\ffmpeg\ffprobe.exe',
    'ThirdPartyNotices.txt'
)
foreach ($required in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $publish $required) -PathType Leaf)) {
        throw "Portable package is missing $required."
    }
}

$ffmpegVersionOutput = @(& (Join-Path $publish 'tools\ffmpeg\ffmpeg.exe') -version 2>&1)
if ($LASTEXITCODE -ne 0 -or $ffmpegVersionOutput.Count -eq 0) {
    throw 'Bundled ffmpeg could not be executed.'
}
$ffmpegVersion = [string]$ffmpegVersionOutput[0]

$ffprobeVersionOutput = @(& (Join-Path $publish 'tools\ffmpeg\ffprobe.exe') -version 2>&1)
if ($LASTEXITCODE -ne 0 -or $ffprobeVersionOutput.Count -eq 0) {
    throw 'Bundled ffprobe could not be executed.'
}
$ffprobeVersion = [string]$ffprobeVersionOutput[0]
if ($ffmpegVersion -notmatch '^ffmpeg version' -or $ffprobeVersion -notmatch '^ffprobe version') {
    throw 'Bundled FFmpeg tools could not be executed.'
}

$workerToolCheck = & (Join-Path $publish 'worker\HLSDownloader.Worker.exe') --check-tools
if ($LASTEXITCODE -ne 0 -or $workerToolCheck.Count -lt 2 -or
    $workerToolCheck[0] -notmatch 'tools[\\/]ffmpeg[\\/]ffmpeg\.exe$' -or
    $workerToolCheck[1] -notmatch 'tools[\\/]ffmpeg[\\/]ffprobe\.exe$') {
    throw 'The packaged background worker cannot resolve the bundled FFmpeg tools.'
}

if (Get-ChildItem -LiteralPath $publish -Recurse -File | Where-Object { $_.Extension -in '.wvd', '.pem', '.key' }) {
    throw 'A credential or private-key-like file was found in the portable artifact.'
}

Write-Host 'Portable Windows package verification passed.'
