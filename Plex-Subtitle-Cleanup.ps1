<#
.SYNOPSIS
  Removes non-English subtitle tracks from MKV files. Video/audio are copied,
  never re-encoded.

  Default is a DRY RUN: it only lists what it would do. Add -Apply to change files.
  Each file is written to "<name>.mkv.partial", checked, then swapped in.

  Every changed file is marked so the change can be found later:
    - file-level tag  MEDIA_CHANGES = what was done and when
    - one row per file in _media-changes-log.csv in the library root
  Removed subtitle tracks cannot be restored.

.EXAMPLE
  .\Remove-ForeignSubs.ps1 -Root "\\Hippo\Videos\Movies"                    # dry run
  .\Remove-ForeignSubs.ps1 -Root "\\Hippo\Videos\Movies" -Apply -Limit 3    # test on 3 files
  .\Remove-ForeignSubs.ps1 -Root "\\Hippo\Videos\Movies" -Apply             # full run
#>
param(
    [Parameter(Mandatory)][string]$Root,
    [string[]]$Keep = @('eng', 'en', 'und'),
    [switch]$RemoveForced,   # foreign 'forced' tracks are kept unless this is set
    [switch]$Apply,
    [int]$Limit = 0,         # stop after this many files (0 = no limit)
    [string]$LogPath         # default: <Root>\_media-changes-log.csv
)

foreach ($tool in 'ffmpeg', 'ffprobe') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool not found. Install ffmpeg (winget install Gyan.FFmpeg) and open a new terminal."
    }
}
$Root = (Resolve-Path -LiteralPath $Root).ProviderPath
if (-not $LogPath) { $LogPath = Join-Path $Root '_media-changes-log.csv' }
$today = Get-Date -Format 'yyyy-MM-dd'

function Get-Probe([string]$Path) {
    $json = & ffprobe -v error `
        -show_entries "stream=index,codec_type,codec_name:stream_tags=language:stream_disposition:format_tags" `
        -of json -i $Path 2>$null
    $exit = $LASTEXITCODE
    try { $d = ($json -join "`n") | ConvertFrom-Json } catch { return $null }
    if (-not $d -or ($exit -ne 0 -and -not $d.streams)) { return $null }
    return $d
}

function Get-Lang($Stream) {
    if ($Stream.tags -and $Stream.tags.language) { $Stream.tags.language.ToLower() } else { 'und' }
}

$files = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter *.mkv
$planned = 0; $changed = 0; $failed = 0; $savedBytes = 0

foreach ($f in $files) {
    if ($Limit -and $planned -ge $Limit) { break }

    $probe = Get-Probe $f.FullName
    if (-not $probe) { Write-Warning "Could not read, skipped: $($f.FullName)"; continue }
    $streams = @($probe.streams)

    $video = @($streams | Where-Object codec_type -eq 'video')
    $audio = @($streams | Where-Object codec_type -eq 'audio')
    $subs  = @($streams | Where-Object codec_type -eq 'subtitle')

    $remove = @($subs | Where-Object {
        ($Keep -notcontains (Get-Lang $_)) -and ($RemoveForced -or -not ($_.disposition -and $_.disposition.forced))
    })
    if (-not $remove.Count) { continue }
    $planned++

    $langs = ($remove | ForEach-Object { Get-Lang $_ } | Sort-Object -Unique) -join ', '
    Write-Host ("`n[{0}] {1}  ({2:N1} GB)" -f $planned, $f.Name, ($f.Length / 1GB)) -ForegroundColor Cyan
    Write-Host "  remove $($remove.Count) subtitle tracks: $langs"
    if (-not $Apply) { continue }

    # Record the change in a file-level tag, appending to any earlier entry
    $note = "$today Remove-ForeignSubs: removed $($remove.Count) subtitle tracks ($langs)"
    $previous = if ($probe.format.tags) { $probe.format.tags.MEDIA_CHANGES }
    if ($previous) { $note = "$previous | $note" }

    $tmp = $f.FullName + '.partial'
    $ffArgs = @('-hide_banner', '-nostdin', '-loglevel', 'error', '-stats', '-y', '-i', $f.FullName, '-map', '0')
    foreach ($s in $remove) { $ffArgs += '-map', "-0:$($s.index)" }
    # The MKV muxer otherwise marks the first subtitle as default when none is,
    # which would turn subtitles on in Plex - so copy every track's flags explicitly
    $out = 0
    foreach ($s in $streams) {
        if ($remove.index -contains $s.index) { continue }
        $flags = if ($s.disposition) { @($s.disposition.PSObject.Properties | Where-Object { $_.Value -eq 1 } | ForEach-Object Name) } else { @() }
        $ffArgs += "-disposition:$out", $(if ($flags.Count) { $flags -join '+' } else { '0' })
        $out++
    }
    $ffArgs += '-c', 'copy', '-metadata', "MEDIA_CHANGES=$note", '-f', 'matroska', $tmp

    & ffmpeg @ffArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "  ffmpeg failed - original kept"
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue; $failed++; continue
    }

    # Check the new file has the track counts we expect before replacing anything
    $new = Get-Probe $tmp
    $newStreams = if ($new) { @($new.streams) } else { @() }
    $ok = $new -and
        @($newStreams | Where-Object codec_type -eq 'video').Count -eq $video.Count -and
        @($newStreams | Where-Object codec_type -eq 'audio').Count -eq $audio.Count -and
        @($newStreams | Where-Object codec_type -eq 'subtitle').Count -eq ($subs.Count - $remove.Count)
    if (-not $ok) {
        Write-Warning "  verification failed - original kept"
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue; $failed++; continue
    }

    $newSize = (Get-Item -LiteralPath $tmp).Length
    try {
        Move-Item -LiteralPath $tmp -Destination $f.FullName -Force -ErrorAction Stop
    } catch {
        Write-Warning "  could not replace original (in use?) - original kept: $($_.Exception.Message)"
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue; $failed++; continue
    }

    [pscustomobject]@{
        Date         = $today
        Script       = 'Remove-ForeignSubs'
        File         = $f.FullName.Substring($Root.TrimEnd('\').Length).TrimStart('\')
        SubsRemoved  = $remove.Count
        SubLanguages = $langs
        SizeBeforeGB = [math]::Round($f.Length / 1GB, 2)
        SizeAfterGB  = [math]::Round($newSize / 1GB, 2)
    } | Export-Csv -LiteralPath $LogPath -Append -NoTypeInformation -Encoding UTF8

    $saved = $f.Length - $newSize
    $changed++; $savedBytes += $saved
    Write-Host ("  done, saved {0:N0} MB" -f ($saved / 1MB)) -ForegroundColor Green
}

Write-Host "`n==== Summary ====" -ForegroundColor Yellow
if ($Apply) {
    Write-Host ("Files changed:  {0}" -f $changed)
    Write-Host ("Failed/kept:    {0}" -f $failed)
    Write-Host ("Space saved:    {0:N2} GB" -f ($savedBytes / 1GB))
    if ($changed) { Write-Host "Log:            $LogPath" }
} else {
    Write-Host ("DRY RUN - {0} files would be changed. Re-run with -Apply to make changes." -f $planned)
}
