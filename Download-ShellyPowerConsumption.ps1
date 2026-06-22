<#
.SYNOPSIS
    Downloads daily (hourly-granularity) power-consumption CSV files from Shelly Cloud
    for every day in a given date range.

.DESCRIPTION
    Shelly Cloud only returns hourly consumption data when you export a SINGLE day.
    This script loops over each day between $DateFrom and $DateTo, requests the
    hourly data (which the API returns as JSON), converts it to CSV, and saves it
    as power_YYYY-MM-DD.csv in $OutputFolder.

    It respects Shelly's "1 request per second" limit, retries on transient errors,
    can skip already-downloaded days (so an interrupted run can be resumed by just
    running it again), and can optionally merge everything into one combined CSV.

.NOTES
    Works in Windows PowerShell 5.1 and PowerShell 7+.
#>

# ============================================================================
#  CONFIGURATION  -  edit the values below, then run the script
# ============================================================================

# --- Your Shelly credentials / device --------------------------------------
$DeviceId = "PUT_YOUR_DEVICE_ID_HERE"
$AuthKey  = "PUT_YOUR_AUTH_KEY_HERE"

# --- Date range (inclusive). Format: YYYY-MM-DD -----------------------------
$DateFrom = "2025-03-01"
$DateTo   = "2025-03-31"

# --- API endpoint details (usually no need to change) -----------------------
$Server   = "shelly-60-eu.shelly.cloud"   # the server shard tied to YOUR account
$Endpoint = "em-3p"                        # meter type in the URL path (3-phase EM)
$Channel  = 0

# --- Output / behaviour ------------------------------------------------------
$OutputFolder     = Join-Path $PSScriptRoot "ShellyData"   # where CSVs are saved
$DelaySeconds     = 1.9     # pause between requests (keep >= 1 for the rate limit)
$SkipExisting     = $true   # don't re-download a day that's already on disk
$MergeIntoOneFile = $true   # also produce one combined CSV at the end
$TotalsOnly       = $false  # $false = log all 3 phases/channels separately (current behaviour)
                            # $true  = log ONLY the per-hour sum of the 3 phases
                            #          (no "channel" column; files named power_total_*.csv)
$UseDotDecimal    = $false  # $true = use dot as decimal separator (e.g. 116.35),
                            #         unquoted numbers, ideal for pandas/English Excel.
                            # $false = keep your system locale (e.g. comma: "116,35").
                            # Pick ONE and don't mix it across files you intend to merge.

# ============================================================================
#  SCRIPT  -  you normally don't need to edit anything below this line
# ============================================================================

# Make sure modern TLS is used (matters on Windows PowerShell 5.1)
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# If requested, format numbers with a dot decimal separator (locale-independent).
if ($UseDotDecimal) {
    [System.Threading.Thread]::CurrentThread.CurrentCulture =
        [System.Globalization.CultureInfo]::InvariantCulture
}

# --- Validate dates ----------------------------------------------------------
try {
    $start = [datetime]::ParseExact($DateFrom, 'yyyy-MM-dd', $null)
    $end   = [datetime]::ParseExact($DateTo,   'yyyy-MM-dd', $null)
} catch {
    Write-Error "DateFrom / DateTo must be in YYYY-MM-DD format (e.g. 2025-03-01)."
    return
}
if ($end -lt $start) {
    Write-Error "DateTo ($DateTo) is earlier than DateFrom ($DateFrom)."
    return
}

# --- Prepare output folder ---------------------------------------------------
if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder | Out-Null
}

# Totals and per-phase files use different name prefixes so the two modes never
# clash (skip-existing stays correct, and the merge picks the right set).
$filePrefix = if ($TotalsOnly) { "power_total_" } else { "power_" }
$dayRegex   = "^$([regex]::Escape($filePrefix))\d{4}-\d{2}-\d{2}\.csv$"

# --- Download helper -----------------------------------------------------
# The API returns JSON (not a ready-made CSV), so we fetch it, pull out the
# hourly records, and write them to a CSV ourselves. Depending on $TotalsOnly we
# take either the per-phase "history" groups or the combined "sum" group.
function Get-ShellyCsv {
    param(
        [string]$Url,
        [string]$OutFile,
        [bool]$TotalsOnly
    )
    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing `
                                      -TimeoutSec 60 -ErrorAction Stop
            $raw = $resp.Content
            if ([string]::IsNullOrWhiteSpace($raw)) {
                throw "Empty response from server."
            }

            try {
                $data = $raw | ConvertFrom-Json
            } catch {
                throw "Response was not valid JSON: $($raw.Substring(0,[Math]::Min(200,$raw.Length)))"
            }

            # A genuine API failure looks like {"isok":false,...}.
            if (($data.PSObject.Properties.Name -contains 'isok') -and (-not $data.isok)) {
                throw "API reported an error: $raw"
            }

            if ($TotalsOnly) {
                # The hourly sum of all phases lives in the top-level "sum" key.
                # Its records have no "channel" field, so that column drops out.
                if (-not $data.sum) {
                    throw "No 'sum' (totals) data in response: $($raw.Substring(0,[Math]::Min(200,$raw.Length)))"
                }
                $records = $data.sum
            } else {
                # "history" is an array of arrays (one per phase) -> flatten one level.
                if (-not $data.history) {
                    throw "No 'history' data in response: $($raw.Substring(0,[Math]::Min(200,$raw.Length)))"
                }
                $records = foreach ($group in $data.history) { $group }
            }
            if (-not $records) {
                throw "Response contained no records (no data for this day?)."
            }

            # On the spring-forward DST day the skipped local hour (e.g. 02:00) comes
            # back as a placeholder row with all measurements empty - drop those.
            # We filter on empty measurements, NOT on duplicate timestamps, so the
            # fall-back day (where 02:00 occurs twice, both with real data) is kept.
            $records = $records | Where-Object {
                $null -ne $_.consumption -and "$($_.consumption)".Trim() -ne ''
            }
            if (-not $records) {
                throw "All records were empty for this day."
            }

            # Stamp the timezone onto every row (useful once daily files are merged).
            $tz   = $data.timezone
            $rows = $records | ForEach-Object {
                $_ | Add-Member -NotePropertyName 'timezone' -NotePropertyValue $tz -Force -PassThru
            }

            $rows | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8
            return $true
        }
        catch {
            if ($attempt -lt $maxAttempts) {
                Write-Warning "   attempt $attempt failed: $($_.Exception.Message)  -> retrying in 3s"
                Start-Sleep -Seconds 3
            } else {
                Write-Warning "   FAILED after $maxAttempts attempts: $($_.Exception.Message)"
                return $false
            }
        }
    }
}

# --- Main loop ---------------------------------------------------------------
$totalDays = ($end - $start).Days + 1
$dayIndex  = 0
$ok = 0; $failed = 0; $skipped = 0

Write-Host "Downloading $totalDays day(s) of data: $DateFrom .. $DateTo" -ForegroundColor Cyan
Write-Host "Saving to: $OutputFolder`n"

$current = $start
while ($current -le $end) {
    $dayIndex++
    $dateStr = $current.ToString('yyyy-MM-dd')
    $outFile = Join-Path $OutputFolder "$filePrefix$dateStr.csv"

    Write-Progress -Activity "Downloading Shelly power data" `
                   -Status "$dateStr ($dayIndex / $totalDays)" `
                   -PercentComplete (($dayIndex / $totalDays) * 100)

    if ($SkipExisting -and (Test-Path $outFile)) {
        Write-Host "[$dayIndex/$totalDays] $dateStr  - already exists, skipping" -ForegroundColor DarkGray
        $skipped++
        $current = $current.AddDays(1)
        continue
    }

    $url = "https://$Server/v2/statistics/power-consumption/$Endpoint" +
           "?id=$DeviceId&channel=$Channel&date_range=day" +
           "&date_from=$dateStr&date_to=$dateStr&auth_key=$AuthKey"

    Write-Host "[$dayIndex/$totalDays] $dateStr  - downloading..." -NoNewline
    if (Get-ShellyCsv -Url $url -OutFile $outFile -TotalsOnly $TotalsOnly) {
        Write-Host " done" -ForegroundColor Green
        $ok++
    } else {
        Write-Host ""   # newline after the inline warning(s)
        $failed++
    }

    # Respect the 1-request-per-second limit (no need to wait after the last day)
    if ($current -lt $end) { Start-Sleep -Seconds $DelaySeconds }

    $current = $current.AddDays(1)
}

Write-Progress -Activity "Downloading Shelly power data" -Completed

# --- Optional: merge all daily files into one --------------------------------
# NOTE: this assumes each daily CSV has exactly ONE header row. If the format
# turns out different, just set $MergeIntoOneFile = $false; the per-day files
# are always written regardless.
if ($MergeIntoOneFile) {
    $files = Get-ChildItem -Path $OutputFolder -Filter "$filePrefix*.csv" |
             Where-Object { $_.Name -match $dayRegex } |
             Sort-Object Name
    if ($files.Count -gt 0) {
        $mergedPath = Join-Path $OutputFolder "${filePrefix}MERGED_${DateFrom}_to_${DateTo}.csv"
        if (Test-Path $mergedPath) { Remove-Item $mergedPath -Force }

        $isFirst = $true
        foreach ($f in $files) {
            $lines = Get-Content -Path $f.FullName
            if ($lines.Count -eq 0) { continue }
            if ($isFirst) {
                $lines | Set-Content -Path $mergedPath                 # keep header
                $isFirst = $false
            } else {
                $lines | Select-Object -Skip 1 | Add-Content -Path $mergedPath  # drop header
            }
        }
        Write-Host "`nMerged $($files.Count) file(s) into:" -ForegroundColor Cyan
        Write-Host "  $mergedPath"
    }
}

# --- Summary -----------------------------------------------------------------
Write-Host "`n==================== SUMMARY ====================" -ForegroundColor Cyan
Write-Host "  Downloaded : $ok"
Write-Host "  Skipped    : $skipped"
Write-Host "  Failed     : $failed"
Write-Host "  Folder     : $OutputFolder"
Write-Host "================================================="
if ($failed -gt 0) {
    Write-Host "Some days failed. Just re-run the script - with `$SkipExisting = `$true it only retries the missing days." -ForegroundColor Yellow
}
