<#
.SYNOPSIS
  Scans a movie library for embedded non-English subtitle tracks and estimates
  how much space removing them would save. Read-only: nothing is modified.

.EXAMPLE
  .\Find-ForeignSubs.ps1 -Root "\\NAS\video\Movies"
  .\Find-ForeignSubs.ps1 -Root "\\NAS\video\Movies" -Csv .\foreign-subs.csv
#>
param(
    [Parameter(Mandatory)][string]$Root,
    # Languages to keep. 'und' (unlabelled) is kept by default and reported separately.
    [string[]]$Keep = @('eng', 'en', 'und'),
    [string]$Csv
)

$videoExt = '.mkv', '.mp4', '.m4v', '.m2ts', '.ts', '.avi'

# Fallback sizes when a file has no per-track size tag
$estimateBytes = @{
    'hdmv_pgs_subtitle' = 30MB   # Blu-ray image subs
    'dvd_subtitle'      = 15MB   # DVD image subs
}
$defaultEstimate = 100KB         # text subs (srt/ass/mov_text)

if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    throw "ffprobe not found. Install ffmpeg (winget install Gyan.FFmpeg) and open a new terminal."
}

$files = Get-ChildItem -LiteralPath $Root -Recurse -File |
    Where-Object { $videoExt -contains $_.Extension.ToLower() }

$results = New-Object System.Collections.Generic.List[object]
$failed  = New-Object System.Collections.Generic.List[string]
$undCount = 0
$i = 0

foreach ($f in $files) {
    $i++
    Write-Progress -Activity "Scanning subtitles" -Status $f.Name -PercentComplete ($i / [math]::Max($files.Count, 1) * 100)

    # Decoder noise (e.g. Dolby Vision RPU or dvdsub warnings) goes to stderr and can set a
    # non-zero exit code even when the stream list is fine, so trust the JSON instead.
    $json = & ffprobe -v error -select_streams s `
        -show_entries "stream=index,codec_name:stream_tags:stream_disposition=forced" `
        -of json -i $f.FullName 2>$null
    $exit = $LASTEXITCODE
    try { $data = ($json -join "`n") | ConvertFrom-Json } catch { $data = $null }
    if (-not $data -or ($exit -ne 0 -and -not $data.streams)) { $failed.Add($f.FullName); continue }
    foreach ($s in $data.streams) {
        $tags = $s.tags
        $lang = if ($tags -and $tags.language) { $tags.language.ToLower() } else { 'und' }

        if ($lang -eq 'und') { $undCount++ }
        if ($Keep -contains $lang) { continue }

        # MKV stores per-track size as NUMBER_OF_BYTES or NUMBER_OF_BYTES-<lang>
        $sizeTag = if ($tags) { $tags.PSObject.Properties | Where-Object { $_.Name -like 'NUMBER_OF_BYTES*' } | Select-Object -First 1 }
        if ($sizeTag) {
            $bytes = [int64]$sizeTag.Value; $estimated = $false
        } else {
            $bytes = if ($estimateBytes.ContainsKey($s.codec_name)) { $estimateBytes[$s.codec_name] } else { $defaultEstimate }
            $estimated = $true
        }

        $results.Add([pscustomobject]@{
            Folder    = $f.Directory.Name
            File      = $f.Name
            Path      = $f.FullName
            Stream    = $s.index
            Language  = $lang
            Codec     = $s.codec_name
            Title     = if ($tags) { $tags.title } else { $null }
            Forced    = [bool]($s.disposition -and $s.disposition.forced)
            SizeMB    = [math]::Round($bytes / 1MB, 1)
            Estimated = $estimated
        })
    }
}
Write-Progress -Activity "Scanning subtitles" -Completed

if ($failed.Count) {
    Write-Host ("`nCould not read {0} file(s) - possibly corrupt or incomplete:" -f $failed.Count) -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "  $_" }
}

if ($results.Count -eq 0) {
    Write-Host "No non-English subtitle tracks found in $($files.Count) files." -ForegroundColor Green
    return
}

# Per-file report
$byFile = $results | Group-Object Path | Sort-Object { ($_.Group | Measure-Object SizeMB -Sum).Sum } -Descending
foreach ($g in $byFile) {
    $sum = ($g.Group | Measure-Object SizeMB -Sum).Sum
    Write-Host ("`n{0}  ({1} tracks, ~{2:N1} MB)" -f $g.Group[0].File, $g.Count, $sum) -ForegroundColor Cyan
    $g.Group | Format-Table Stream, Language, Codec, Title, Forced, SizeMB, Estimated -AutoSize | Out-Host
}

# Summary
$totalMB  = ($results | Measure-Object SizeMB -Sum).Sum
$estCount = ($results | Where-Object Estimated).Count
Write-Host "==== Summary ====" -ForegroundColor Yellow
Write-Host ("Files scanned:            {0}" -f $files.Count)
Write-Host ("Files with foreign subs:  {0}" -f $byFile.Count)
Write-Host ("Foreign subtitle tracks:  {0}" -f $results.Count)
Write-Host ("Approx. savings:          {0:N2} GB" -f ($totalMB / 1024))
if ($estCount) { Write-Host ("  ({0} track sizes estimated - no size tag in file)" -f $estCount) }
if ($undCount) { Write-Host ("Unlabelled ('und') tracks kept, not counted: {0}" -f $undCount) }
$forced = ($results | Where-Object Forced).Count
if ($forced) { Write-Host ("Note: {0} candidate tracks are flagged 'forced' - review before deleting." -f $forced) -ForegroundColor Magenta }

if ($Csv) {
    $results | Export-Csv -LiteralPath $Csv -NoTypeInformation -Encoding UTF8
    Write-Host "Details written to $Csv"
}
