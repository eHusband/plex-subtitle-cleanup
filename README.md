# Plex Subtitle Cleanup

Two PowerShell scripts for finding and removing non-English subtitle tracks embedded in a movie library. Blu-ray rips often carry 20+ image-based (PGS) subtitle tracks at 20–50 MB each, which adds up to a lot of space across a library.

| Script | What it does | Changes files? |
|---|---|---|
| `Find-ForeignSubs.ps1` | Scans the library and reports foreign subtitle tracks and the estimated space saving | No, read-only |
| `Plex-Subtitle-Cleanup.ps1` | Removes those tracks from MKV files | Only with `-Apply` |

Video and audio are **copied, never re-encoded**, so there is no quality loss and each file takes about as long as copying it.

## Requirements

- **PowerShell 7** (`pwsh`). Install with `winget install Microsoft.PowerShell`.
- **ffmpeg / ffprobe** on your PATH. Install with `winget install Gyan.FFmpeg`, then open a new terminal.
- Free space on the target drive at least the size of the largest movie, since each file is rewritten before the original is replaced.

If Windows refuses to run the scripts after downloading them, unblock them once:

```powershell
Unblock-File .\Find-ForeignSubs.ps1, .\Plex-Subtitle-Cleanup.ps1
```

## Quick start

```powershell
# 1. See what you'd save (read-only)
pwsh -File .\Find-ForeignSubs.ps1 -Root "\\NAS\Videos\Movies"

# 2. Preview what would be removed (dry run, the default)
pwsh -File .\Plex-Subtitle-Cleanup.ps1 -Root "\\NAS\Videos\Movies"

# 3. Try it on a few files first
pwsh -File .\Plex-Subtitle-Cleanup.ps1 -Root "\\NAS\Videos\Movies" -Apply -Limit 3

# 4. Run on everything
pwsh -File .\Plex-Subtitle-Cleanup.ps1 -Root "\\NAS\Videos\Movies" -Apply
```

`-Root` can be a network share or a local folder. Subfolders are searched recursively, so the usual `Movies\Title (Year)\Title.mkv` layout works as-is.

## Find-ForeignSubs.ps1

Scans `.mkv`, `.mp4`, `.m4v`, `.m2ts`, `.ts` and `.avi` files and lists every subtitle track whose language isn't in the keep list, with sizes and a total.

| Parameter | Default | Description |
|---|---|---|
| `-Root` | *(required)* | Folder to scan |
| `-Keep` | `eng, en, und` | Languages to keep (ISO 639 codes as stored in the file) |
| `-Csv` | — | Also write every candidate track to a CSV file |

```powershell
# Keep English and French
pwsh -File .\Find-ForeignSubs.ps1 -Root "D:\Movies" -Keep eng, en, fre, fra, und

# Save the full list for Excel
pwsh -File .\Find-ForeignSubs.ps1 -Root "D:\Movies" -Csv .\foreign-subs.csv
```

**About the sizes:** MKV files usually record each track's size (`NUMBER_OF_BYTES`). When they don't, the script estimates it (PGS 30 MB, DVD 15 MB, text 100 KB), and the summary says how many sizes were estimated.

Files that ffprobe can't read are listed in red at the end. They are usually corrupt or incomplete downloads.

## Plex-Subtitle-Cleanup.ps1

Removes the foreign subtitle tracks from `.mkv` files. Other containers are skipped.

| Parameter | Default | Description |
|---|---|---|
| `-Root` | *(required)* | Folder to process |
| `-Keep` | `eng, en, und` | Languages to keep |
| `-Apply` | off | Actually change files. Without it the script is a dry run. |
| `-Limit` | `0` (no limit) | Stop after this many files, which is useful for testing |
| `-RemoveForced` | off | Also remove foreign tracks flagged *forced* (see below) |
| `-LogPath` | `<Root>\_media-changes-log.csv` | Where to write the change log |

```powershell
# Dry run, keeping English and Spanish
pwsh -File .\Plex-Subtitle-Cleanup.ps1 -Root "D:\Movies" -Keep eng, en, spa, und

# Process 50 files per session
pwsh -File .\Plex-Subtitle-Cleanup.ps1 -Root "D:\Movies" -Apply -Limit 50

# Also remove forced foreign tracks
pwsh -File .\Plex-Subtitle-Cleanup.ps1 -Root "D:\Movies" -Apply -RemoveForced
```

### How each file is processed

1. ffmpeg copies the file to `<name>.mkv.partial` without the removed tracks.
2. The new file is checked to make sure it has the same number of video and audio tracks and the expected number of subtitle tracks.
3. Only then is the original replaced. If anything fails, the original is left untouched and the `.partial` file is removed.

Each track's flags (default, forced, SDH/hearing-impaired and so on) are copied explicitly. Without this, ffmpeg's MKV writer marks the first remaining subtitle as default, which turns subtitles on in Plex.

You can stop the script at any time (Ctrl+C). Already-processed files no longer have foreign subtitles, so they are skipped on the next run.

### Forced subtitles

A *forced* track only shows text for parts of a movie in another language, such as signs or an alien language. These tracks are **kept by default**, even when they are foreign, because some are mislabelled and are actually the English forced track. Check them in the `Find-ForeignSubs` output before using `-RemoveForced`.

### Tracks labelled `und`

`und` (undefined) tracks have no language tag. They are kept by default because they are often the English track. Remove `und` from `-Keep` only if you're sure.

## Tracking changes

Every changed file is marked in two places, so you can tell years later what was done. Both record the change under the name `Remove-ForeignSubs`, the script's original name.

**1. A tag inside the file.** It isn't visible in Plex. Read it with:

```powershell
ffprobe -v error -show_entries format_tags=MEDIA_CHANGES -of default=nw=1 "D:\Movies\Some Movie (2020)\Some Movie (2020).mkv"
```

```
TAG:MEDIA_CHANGES=2026-10-27 Remove-ForeignSubs: removed 18 subtitle tracks (chi, cze, dan, ...)
```

If a file is processed again later, the new entry is added to the end, separated by ` | `.

**2. A CSV log** in the library root (`_media-changes-log.csv`), with one row per file:

| Column | Example |
|---|---|
| Date | `2026-10-27` |
| Script | `Remove-ForeignSubs` |
| File | `Some Movie (2020)\Some Movie (2020).mkv` |
| SubsRemoved | `18` |
| SubLanguages | `chi, cze, dan, ...` |
| SizeBeforeGB / SizeAfterGB | `42.10` / `41.37` |

## After running: Plex

Plex keeps showing the old subtitle list until it re-reads the files. Selecting a removed track can then stall playback. To fix this, refresh the media info:

- **Whole library:** open the library, click **⋯**, then **Analyze**. Or select all items and choose **Analyze**.
- **One movie:** click **⋯**, then **Analyze**.

## Tips

- **Don't play files while the script runs.** A file that's open can't be replaced. It is skipped and counted under *Failed/kept*.
- **Speed** is limited by disk and network throughput, not CPU. Over 1 GbE expect about 100 MB/s. On 2.5 GbE or faster, the NAS disks are usually the limit.
- **Running several copies in parallel** usually makes things slower, because they compete for the same disks.

## Warning

**Removed subtitle tracks cannot be restored** except from a backup or by re-ripping. Run the dry run first, test with `-Limit`, and make sure you have a backup of anything you can't replace.

## License

MIT. See `LICENSE`.
