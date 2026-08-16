param(
    [Parameter(Mandatory = $true)]
    [string]$PublishDirectory,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactDirectory,

    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,

    [string]$FFmpegDirectory
)

$ErrorActionPreference = 'Stop'
$publish = (Resolve-Path -LiteralPath $PublishDirectory).Path
$artifact = [System.IO.Path]::GetFullPath($ArtifactDirectory)
$repository = (Resolve-Path -LiteralPath $RepositoryRoot).Path

$repositoryPrefix = $repository.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
if (-not $publish.StartsWith($repositoryPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'PublishDirectory must be inside the repository workspace.'
}

New-Item -ItemType Directory -Force -Path $artifact | Out-Null
$toolDirectory = Join-Path $publish 'tools\ffmpeg'
New-Item -ItemType Directory -Force -Path $toolDirectory | Out-Null

$ffmpeg = $null
$ffprobe = $null
if ($FFmpegDirectory) {
    $resolvedTools = (Resolve-Path -LiteralPath $FFmpegDirectory).Path
    $ffmpeg = Get-Item -LiteralPath (Join-Path $resolvedTools 'ffmpeg.exe') -ErrorAction SilentlyContinue
    $ffprobe = Get-Item -LiteralPath (Join-Path $resolvedTools 'ffprobe.exe') -ErrorAction SilentlyContinue
}
else {
    $chocolateyRoot = if ($env:ChocolateyInstall) { $env:ChocolateyInstall } else { 'C:\ProgramData\chocolatey' }
    $packageToolRoot = Join-Path $chocolateyRoot 'lib\ffmpeg\tools'
    $ffmpeg = Get-ChildItem -LiteralPath $packageToolRoot -Filter 'ffmpeg.exe' -File -Recurse |
        Where-Object { $_.Directory.Name -eq 'bin' } |
        Select-Object -First 1
    $ffprobe = Get-ChildItem -LiteralPath $packageToolRoot -Filter 'ffprobe.exe' -File -Recurse |
        Where-Object { $_.Directory.Name -eq 'bin' } |
        Select-Object -First 1
}
if (-not $ffmpeg -or -not $ffprobe) {
    throw 'The configured FFmpeg source did not contain ffmpeg.exe and ffprobe.exe.'
}

Copy-Item -LiteralPath $ffmpeg.FullName -Destination (Join-Path $toolDirectory 'ffmpeg.exe')
Copy-Item -LiteralPath $ffprobe.FullName -Destination (Join-Path $toolDirectory 'ffprobe.exe')
Copy-Item -LiteralPath (Join-Path $repository 'windows\ThirdPartyNotices.txt') -Destination $publish

& (Join-Path $toolDirectory 'ffmpeg.exe') -hide_banner -L 2>&1 |
    Out-File -LiteralPath (Join-Path $toolDirectory 'FFmpeg-LICENSE.txt') -Encoding utf8
if ($LASTEXITCODE -ne 0) {
    throw "ffmpeg -L failed with exit code $LASTEXITCODE."
}

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
    'tools\ffmpeg\FFmpeg-LICENSE.txt',
    'ThirdPartyNotices.txt'
)
foreach ($required in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $publish $required) -PathType Leaf)) {
        throw "Portable package is missing $required."
    }
}

$ffmpegVersionOutput = @(& (Join-Path $toolDirectory 'ffmpeg.exe') -version 2>&1)
if ($LASTEXITCODE -ne 0 -or $ffmpegVersionOutput.Count -eq 0) {
    throw 'The packaged ffmpeg executable could not be started.'
}
Write-Host ([string]$ffmpegVersionOutput[0])

$ffprobeVersionOutput = @(& (Join-Path $toolDirectory 'ffprobe.exe') -version 2>&1)
if ($LASTEXITCODE -ne 0 -or $ffprobeVersionOutput.Count -eq 0) {
    throw 'The packaged ffprobe executable could not be started.'
}
Write-Host ([string]$ffprobeVersionOutput[0])

$zipPath = Join-Path $artifact 'HLSDownloader-Windows-win-x64.zip'
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath
}

Compress-Archive -Path (Join-Path $publish '*') -DestinationPath $zipPath -CompressionLevel Optimal
$hash = Get-FileHash -LiteralPath $zipPath -Algorithm SHA256
"$($hash.Hash.ToLowerInvariant())  $($hash.Path | Split-Path -Leaf)" |
    Out-File -LiteralPath (Join-Path $artifact 'HLSDownloader-Windows-win-x64.sha256') -Encoding ascii
Write-Host "Packaged $zipPath"
