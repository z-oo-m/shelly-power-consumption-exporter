# Shelly Cloud Power Consumption Exporter

A PowerShell script that bulk-downloads **hourly** power-consumption data from
[Shelly Cloud](https://shelly-api-docs.shelly.cloud/cloud-control-api/communication-v2)
and saves it as daily CSV files.

Shelly Cloud only returns *hourly* granularity when you export a **single day** at
a time. Getting a full year that way means 365 manual downloads. This script does
it for you: set a date range once, run it, and walk away.

---

## Features

- Downloads one CSV per day for any date range you specify.
- Respects Shelly's **1 request per second** limit.
- **Resumable** — already-downloaded days are skipped, so an interrupted run just
  needs to be started again.
- **Automatic retries** on transient network errors (3 attempts per each day).
- Detects real API errors (e.g. bad auth) and reports them instead of saving junk.
- Correctly handles the two **daylight-saving** changeover days each year.
- Optional merge of all daily files into one combined CSV.
- Choose between exporting **all three phases** or just the **combined totals**.
- Optional dot/comma decimal separator for locale-independent output.

---

## Requirements

- **Windows PowerShell 5.1** (built into Windows 10/11) **or PowerShell 7+**
  (Windows, macOS, Linux).
- A Shelly Cloud account with a compatible energy meter (developed and tested
  against a 3-phase EM, i.e. the `em-3p` endpoint).
- Your **Device ID**, **Auth Key**, and your account's **server shard**.

### Getting your credentials

| What | Where to find it |
|------|------------------|
| **Auth Key** | In the Shelly Control Cloud web: User icon → Edit profile info → Home → *Cloud Key* (use button "Get key"). |
| **Server** | Shown alongside the Cloud key (e.g. `shelly-60-eu.shelly.cloud`). It is tied to your account, not to a device. |
| **Device ID** | In the device's settings: Cogwheel icon → Device information → *Device Id*. |

> **Security:** Your Auth Key is a secret that grants access to your account data.
> **Never share your real Auth Key or Device ID.**

---

## Setup & usage

1. Download `Download-ShellyPowerConsumption.ps1`.
2. Open it in any text editor and edit the **Configuration** block at the top
   (at minimum: `$DeviceId`, `$AuthKey`, `$DateFrom`, `$DateTo`; check `$Server`).
3. Run it:

   ```powershell
   .\Download-ShellyPowerConsumption.ps1
   ```

   If Windows blocks the script, allow it for the current session only:

   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   ```

   (or right-click the file → *Properties* → *Unblock*).

CSV files appear in a `ShellyData` folder next to the script. Progress, a summary,
and any failures are printed to the console.

---

## Configuration reference

All settings live in the `CONFIGURATION` block at the top of the script.

| Variable | Default | Description |
|----------|---------|-------------|
| `$DeviceId` | *(placeholder)* | Your Shelly device ID. |
| `$AuthKey` | *(placeholder)* | Your Shelly Cloud authorization key. **Keep this secret.** |
| `$DateFrom` | `2025-03-01` | First day to download, `YYYY-MM-DD`. Inclusive. |
| `$DateTo` | `2025-03-31` | Last day to download, `YYYY-MM-DD`. Inclusive. |
| `$Server` | `shelly-60-eu.shelly.cloud` | The server shard tied to **your** account. Change it to match yours. |
| `$Endpoint` | `em-3p` | Meter-type segment in the API URL path. `em-3p` is a 3-phase energy meter. |
| `$Channel` | `0` | The `channel` query parameter sent to the API. For the 3-phase meter the response contains all phases plus the totals regardless. |
| `$OutputFolder` | `…\ShellyData` | Where CSV files are written. Defaults to a folder next to the script. |
| `$DelaySeconds` | `1.9` | Pause between requests. Keep **≥ 1** to stay within the rate limit. |
| `$SkipExisting` | `$true` | If `$true`, days already on disk are skipped (enables resuming). |
| `$MergeIntoOneFile` | `$true` | If `$true`, also writes a single combined CSV after the run. |
| `$TotalsOnly` | `$false` | Export the combined totals instead of the individual phases. See below. |
| `$UseDotDecimal` | `$false` | `$true` forces a dot decimal separator (`116.35`, unquoted) for tools like pandas or English-locale Excel. `$false` keeps your system locale (e.g. `"116,35"`). Don't mix formats across files you plan to merge. |

---

## The `$TotalsOnly` switch — `history` vs `sum`

The Shelly API doesn't return a ready-made CSV; it returns **JSON**. For a 3-phase
meter, that JSON contains two relevant parts:

- **`history`** — an array of arrays, one inner array **per phase / channel**
  (channel `0`, `1`, `2` = phases A, B, C). Each inner array holds one record per
  hour, and each record carries a `channel` field identifying its phase.
- **`sum`** — a single array of hourly records that is the **per-hour total of all
  three phases combined**. These records have **no `channel` field**, since they
  already represent the whole meter.

The script reads one of these depending on `$TotalsOnly`:

- **`$TotalsOnly = $false`** (default) → exports `history`. Every hour appears three
  times (once per phase), and the CSV **includes a `channel` column**.
- **`$TotalsOnly = $true`** → exports `sum`. Every hour appears once as the combined
  figure, and the CSV **has no `channel` column**.

To keep the two modes from interfering, totals files are named
`power_total_YYYY-MM-DD.csv` while per-phase files are `power_YYYY-MM-DD.csv`. This
means switching modes won't make the resume logic think a day is already done, and
the merge step only ever combines files of the same kind.

> **Note:** `sum` is the meter's own total. It can differ from re-adding the three
> phases yourself by about 0.01 due to rounding inside Shelly. Using the meter's
> `sum` is the correct choice; just don't expect it to reconcile to the last digit.

---

## What the script handles

**Daylight-saving time.** Both DST changeover days are handled automatically by a
single rule: drop any hour whose measurements are empty, but **never** deduplicate
by timestamp.

- *Spring forward* (e.g. late March): the skipped local hour (02:00) doesn't exist,
  but the API still emits a placeholder row with all values empty. The script drops
  it, leaving a correct **23-hour** day.
- *Fall back* (e.g. late October): the 02:00 hour happens **twice**, and both rows
  contain real data. Because the script filters on *empty values* — not on repeated
  timestamps — **both hours are kept**, giving a correct **25-hour** day.

**Missing / empty data.** Any row that comes back without a consumption value is
dropped, so empty placeholder rows never pollute your CSVs or skew later statistics.

**API rate limit.** A configurable pause (`$DelaySeconds`, default 1.9 s) keeps the
script under Shelly's 1-request-per-second limit.

**Transient failures.** Each day is attempted up to 3 times with a short backoff
before being marked as failed. Genuine API errors (such as `{"isok":false,...}` for
bad credentials) are detected and reported rather than saved as a "successful" file.

**Interrupted runs.** With `$SkipExisting = $true`, re-running the script only
fetches the days that are still missing — handy for a full year, where the
occasional failure is likely.

---

## Output

Each day produces one CSV with one row per hour (per phase, unless `$TotalsOnly` is
set). Columns come straight from the API and typically include:

`datetime`, `consumption`, `reversed`, `min_voltage`, `max_voltage`, `cost`,
`purpose`, `channel` *(per-phase mode only)*, `tariff_id`, and `timezone` (added by
the script).

If `$MergeIntoOneFile` is enabled, a combined file is also written:
`power_MERGED_<from>_to_<to>.csv` (or `power_total_MERGED_…csv` in totals mode),
with a single header row.

### Units & caveats

- `consumption` is energy per hour (verify the exact unit against a manual export
  from the Shelly portal — typically watt-hours).
- `cost` is in your account's configured currency/tariff.
- On the fall-back day the two 02:00 rows share an identical timestamp string with
  no UTC offset to distinguish them. This is harmless for daily/monthly totals; only
  matters if you need to order those two specific hours.

---

## Disclaimer

This is an unofficial tool and is not affiliated with or endorsed by Shelly /
Allterco Robotics. Use it in accordance with Shelly's API terms.
