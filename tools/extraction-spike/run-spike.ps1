#Requires -Version 7.0
<#
.SYNOPSIS
    Replays a folder of receipt photos through the Development-only extraction endpoint for each
    model alias, scores the results against typed ground truth and writes the spike report.

.DESCRIPTION
    Steps:
      1. Validate <ReceiptsDir>/truth.csv (header file,store,date,total). Every row must name an
         existing JPEG and have a total with a dot as the decimal separator. Nothing is sent when
         validation fails.
      2. Apply each photo's EXIF orientation and resize it to a long edge of at most 2000 px, JPEG
         quality 85, into <OutDir>/resized/. Resize time is not part of the measured latency.
      3. Send one untimed warm-up call per model, then each receipt to each model in turn
         (interleaved), with a 60 s client timeout. Latency is the wall-clock time of the whole HTTP
         call measured here.
      4. Score each call and apply the agreed rules:
           latency  PASS when calls <= 10,000 ms >= ceil(0.95 x N)
           accuracy PASS when exact totals     >= ceil(0.9 x N)
         Errors and timeouts count as over 10 s and as a total mismatch.
      5. Write <OutDir>/results.csv (full values, git-ignored) and the report at -ReportPath
         (aggregates and per-file pass/fail only: no store names, dates or amounts).

    -SelfTest runs the scoring and verdict functions on built-in fixtures (no files, no HTTP) and
    exits 1 when any case fails.

.PARAMETER Prices
    Optional USD prices per 1M input/output tokens, per alias, from the OpenRouter model pages:
    "claude=5/25,gpt=1.25/10". Models without a price show "n/a" for cost.

.EXAMPLE
    pwsh -NoProfile -File tools/extraction-spike/run-spike.ps1 -Prices "claude=5/25,gpt=1.25/10"

.EXAMPLE
    pwsh -NoProfile -File tools/extraction-spike/run-spike.ps1 -SelfTest
#>
[CmdletBinding()]
param(
    [string]$ReceiptsDir = (Join-Path $PSScriptRoot 'receipts'),
    [string]$ApiBase = 'http://localhost:5066',
    [string]$Models = 'claude,gpt',
    [string]$ReportPath = (Join-Path $PSScriptRoot '../../context/changes/extraction-provider-spike/spike-report.md'),
    [string]$Prices = '',
    [string]$OutDir = (Join-Path $PSScriptRoot 'out'),
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$LatencyLimitMs = 10000
$ClientTimeoutSeconds = 60
$MaxLongEdge = 2000
$JpegQuality = 85
$LatencyShare = 0.95d
$AccuracyShare = 0.9d

# Kept ASCII-only on purpose; these are the non-ASCII characters the report needs.
$Tick = [string][char]0x2713   # check mark
$Cross = [string][char]0x2717  # ballot x
$Le = [string][char]0x2264     # less-than or equal

function Stop-Spike([string]$Message) {
    [Console]::Error.WriteLine("run-spike: $Message")
    exit 1
}

# ---------------------------------------------------------------------------------------------
# Pure scoring and verdict functions (exercised by -SelfTest; no files, no HTTP)
# ---------------------------------------------------------------------------------------------

function ConvertTo-InvariantDecimal($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [decimal]) { return $Value }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return [decimal]$Value }
    $text = ([string]$Value).Trim()
    if ($text -eq '') { return $null }
    $parsed = [decimal]0
    if ([decimal]::TryParse($text, [System.Globalization.NumberStyles]::Number, $Invariant, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

# Total match: decimal equality after rounding both sides to 2 places (to the grosz).
function Test-TotalMatch($Truth, $Extracted) {
    $t = ConvertTo-InvariantDecimal $Truth
    $e = ConvertTo-InvariantDecimal $Extracted
    if ($null -eq $t -or $null -eq $e) { return $false }
    $mode = [System.MidpointRounding]::AwayFromZero
    return [decimal]::Round($t, 2, $mode) -eq [decimal]::Round($e, 2, $mode)
}

# Date match: exact yyyy-MM-dd. An empty truth date matches only an empty extracted date.
function Test-DateMatch([string]$Truth, [string]$Extracted) {
    $t = if ($null -eq $Truth) { '' } else { $Truth.Trim() }
    $e = if ($null -eq $Extracted) { '' } else { $Extracted.Trim() }
    return [string]::Equals($t, $e, [System.StringComparison]::Ordinal)
}

# Lower-case letters and digits only: no whitespace, punctuation, quotes or diacritics. FormD does
# not decompose the Polish l-stroke, so it is mapped by hand.
function Get-NormalizedStore([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $lower = $Value.ToLowerInvariant().Replace([string][char]0x0142, 'l')
    $decomposed = $lower.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $decomposed.ToCharArray()) {
        if ([char]::IsLetterOrDigit($ch)) {
            [void]$sb.Append($ch)
        }
    }
    return $sb.ToString().Normalize([System.Text.NormalizationForm]::FormC)
}

# Receipts print the registered company name ("Lidl sp. z o.o. sp. k."), while the typed truth is
# usually the shop sign ("Lidl"), so a store matches when either normalized name contains the other.
# Names shorter than 3 characters must match exactly, so a stray letter cannot match everything.
function Test-StoreMatch([string]$Truth, [string]$Extracted) {
    $t = Get-NormalizedStore $Truth
    $e = Get-NormalizedStore $Extracted
    if ($t -eq $e) { return $true }
    if ($t.Length -lt 3 -or $e.Length -lt 3) { return $false }
    return $e.Contains($t) -or $t.Contains($e)
}

# Adds the per-rule outcomes to one call's result. A failed call (Ok = false) fails every rule,
# whatever its measured time or partial values.
function Get-ScoredResult($Truth, $Result) {
    $ok = [bool]$Result.Ok
    $row = [ordered]@{}
    foreach ($p in $Result.PSObject.Properties) { $row[$p.Name] = $p.Value }
    $row['TruthStore'] = $Truth.Store
    $row['TruthDate'] = $Truth.Date
    $row['TruthTotal'] = $Truth.Total
    $row['WithinLimit'] = $ok -and ($Result.Ms -le $LatencyLimitMs)
    $row['TotalMatch'] = $ok -and (Test-TotalMatch $Truth.Total $Result.Total)
    $row['DateMatch'] = $ok -and (Test-DateMatch $Truth.Date $Result.PurchaseDate)
    $row['StoreMatch'] = $ok -and (Test-StoreMatch $Truth.Store $Result.Store)
    return [pscustomobject]$row
}

# Nearest-rank percentile: the value at rank ceil(fraction x N) in ascending order.
function Get-NearestRank([double[]]$Values, [decimal]$Fraction) {
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    $sorted = [double[]]@($Values | Sort-Object)
    $rank = [int][Math]::Ceiling($Fraction * $sorted.Count)
    if ($rank -lt 1) { $rank = 1 }
    return $sorted[$rank - 1]
}

# Applies the agreed rules to one model's scored rows. Prices are USD per 1M tokens, or $null.
function Get-ModelVerdict([object[]]$Rows, $InputPricePerM = $null, $OutputPricePerM = $null) {
    $n = @($Rows).Count
    if ($n -eq 0) { throw 'Get-ModelVerdict needs at least one row.' }

    $within = @($Rows | Where-Object { $_.WithinLimit }).Count
    $exact = @($Rows | Where-Object { $_.TotalMatch }).Count
    $latencyNeeded = [int][Math]::Ceiling($LatencyShare * $n)
    $accuracyNeeded = [int][Math]::Ceiling($AccuracyShare * $n)

    # Failed calls rank as slower than any measured call.
    $latencies = [double[]]@(foreach ($r in $Rows) { if ($r.Ok) { [double]$r.Ms } else { [double]::PositiveInfinity } })

    $okRows = @($Rows | Where-Object { $_.Ok })
    $tokenRows = @($okRows | Where-Object { $null -ne $_.InputTokens -and $null -ne $_.OutputTokens })
    $avgIn = $null; $avgOut = $null; $cost = $null
    if ($tokenRows.Count -gt 0) {
        $avgIn = [decimal](($tokenRows | Measure-Object -Property InputTokens -Sum).Sum) / $tokenRows.Count
        $avgOut = [decimal](($tokenRows | Measure-Object -Property OutputTokens -Sum).Sum) / $tokenRows.Count
        if ($null -ne $InputPricePerM -and $null -ne $OutputPricePerM) {
            $cost = ($avgIn * [decimal]$InputPricePerM + $avgOut * [decimal]$OutputPricePerM) / 1000000
        }
    }

    $backends = @($okRows | ForEach-Object { $_.ServedBy } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

    return [pscustomobject]@{
        N              = $n
        Within         = $within
        LatencyNeeded  = $latencyNeeded
        LatencyPass    = $within -ge $latencyNeeded
        Exact          = $exact
        AccuracyNeeded = $accuracyNeeded
        AccuracyPass   = $exact -ge $accuracyNeeded
        P95Ms          = Get-NearestRank $latencies 0.95d
        MedianMs       = Get-NearestRank $latencies 0.5d
        DateMatches    = @($Rows | Where-Object { $_.DateMatch }).Count
        StoreMatches   = @($Rows | Where-Object { $_.StoreMatch }).Count
        Errors         = $n - $okRows.Count
        Backends       = $backends
        AvgInputTokens = $avgIn
        AvgOutputTokens = $avgOut
        CostPerReceipt = $cost
    }
}

function Format-Ms($Value) {
    if ($null -eq $Value) { return 'n/a' }
    if ([double]::IsInfinity([double]$Value)) { return 'error' }
    return ([long][Math]::Round([double]$Value)).ToString($Invariant)
}

# Parses "claude=5/25,gpt=1.25/10" into @{ claude = @{ In = 5; Out = 25 }; ... }.
function ConvertFrom-PriceSpec([string]$Spec) {
    $result = @{}
    if ([string]::IsNullOrWhiteSpace($Spec)) { return $result }
    foreach ($entry in $Spec.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $m = [regex]::Match($entry, '^\s*([A-Za-z0-9_-]+)\s*=\s*(\d+(?:\.\d+)?)\s*/\s*(\d+(?:\.\d+)?)\s*$')
        if (-not $m.Success) {
            throw "Price entry '$($entry.Trim())' is not in the form alias=input/output, for example claude=5/25 (USD per 1M tokens, dot as decimal separator)."
        }
        $result[$m.Groups[1].Value] = @{
            In  = [decimal]::Parse($m.Groups[2].Value, $Invariant)
            Out = [decimal]::Parse($m.Groups[3].Value, $Invariant)
        }
    }
    return $result
}

# ---------------------------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------------------------

function New-FixtureRows([int]$Count, [int]$Exact, [int]$Within) {
    for ($i = 0; $i -lt $Count; $i++) {
        [pscustomobject]@{
            Ok           = $true
            Ms           = if ($i -lt $Within) { 4000 } else { 12000 }
            WithinLimit  = $i -lt $Within
            TotalMatch   = $i -lt $Exact
            DateMatch    = $true
            StoreMatch   = $true
            InputTokens  = 1000
            OutputTokens = 200
            ServedBy     = 'Fixture'
        }
    }
}

function New-FixtureResult([bool]$Ok, [long]$Ms, $Total, [string]$Date = '2026-11-01', [string]$Store = 'Example Market') {
    [pscustomobject]@{
        File = 'fixture.jpg'; Alias = 'fixture'; Status = if ($Ok) { '200' } else { '502' }; Ok = $Ok; Ms = $Ms
        ProviderMs = $null; Model = 'fixture/model'; ServedBy = 'Fixture'; InputTokens = 1000; OutputTokens = 200
        Store = $Store; PurchaseDate = $Date; Currency = 'PLN'; Total = $Total; ItemCount = 1; Error = ''
    }
}

function Invoke-SelfTest {
    $script:failures = 0
    function Assert-Case([string]$Name, [bool]$Condition) {
        if ($Condition) { Write-Host "PASS  $Name" } else { Write-Host "FAIL  $Name"; $script:failures++ }
    }

    $truth = [pscustomobject]@{ File = 'fixture.jpg'; Store = 'Example Market'; Date = '2026-11-01'; Total = '12.30' }

    # Accuracy boundary (ceil(0.9 x 20) = 18).
    $v = Get-ModelVerdict @(New-FixtureRows 20 18 20)
    Assert-Case 'accuracy: 18/20 exact totals -> PASS' ($v.AccuracyNeeded -eq 18 -and $v.Exact -eq 18 -and $v.AccuracyPass)
    $v = Get-ModelVerdict @(New-FixtureRows 20 17 20)
    Assert-Case 'accuracy: 17/20 exact totals -> FAIL' ($v.Exact -eq 17 -and -not $v.AccuracyPass)

    # Latency boundary (ceil(0.95 x 20) = 19).
    $v = Get-ModelVerdict @(New-FixtureRows 20 20 19)
    Assert-Case 'latency: 19/20 calls within 10 s -> PASS' ($v.LatencyNeeded -eq 19 -and $v.Within -eq 19 -and $v.LatencyPass)
    $v = Get-ModelVerdict @(New-FixtureRows 20 20 18)
    Assert-Case 'latency: 18/20 calls within 10 s -> FAIL' ($v.Within -eq 18 -and -not $v.LatencyPass)

    # Total equality to the grosz.
    Assert-Case "total: '12.30' vs '12.3' -> match" (Test-TotalMatch '12.30' '12.3')
    Assert-Case "total: '12.30' vs 12.3 (decimal from JSON) -> match" (Test-TotalMatch '12.30' ([decimal]12.3))
    Assert-Case "total: '12.31' vs '12.30' -> mismatch" (-not (Test-TotalMatch '12.31' '12.30'))
    Assert-Case 'total: null extracted -> mismatch' (-not (Test-TotalMatch '12.30' $null))
    Assert-Case "total: '1234.5' vs 1234.50 -> match" (Test-TotalMatch '1234.5' ([decimal]1234.50))

    # Exact-boundary latency: 10,000 ms counts as within, 10,001 ms does not.
    Assert-Case 'latency: 10000 ms -> within' ((Get-ScoredResult $truth (New-FixtureResult $true 10000 '12.30')).WithinLimit)
    Assert-Case 'latency: 10001 ms -> over' (-not (Get-ScoredResult $truth (New-FixtureResult $true 10001 '12.30')).WithinLimit)

    # An error row counts against both rules even when it was fast and carried a matching total.
    $err = Get-ScoredResult $truth (New-FixtureResult $false 800 '12.30')
    Assert-Case 'error row: not within 10 s' (-not $err.WithinLimit)
    Assert-Case 'error row: total mismatch' (-not $err.TotalMatch)
    $good = Get-ScoredResult $truth (New-FixtureResult $true 3000 '12.30')
    $rows = @(@($good) * 18) + @($err, $err)
    $v = Get-ModelVerdict $rows
    Assert-Case 'error rows: 18 good + 2 errors -> latency FAIL (18/20)' ($v.Within -eq 18 -and -not $v.LatencyPass)
    Assert-Case 'error rows: 18 good + 2 errors -> accuracy PASS (18/20), errors = 2' ($v.Exact -eq 18 -and $v.AccuracyPass -and $v.Errors -eq 2)
    $rows = @(@($good) * 17) + @($err, $err, $err)
    $v = Get-ModelVerdict $rows
    Assert-Case 'error rows: 17 good + 3 errors -> accuracy FAIL' ($v.Exact -eq 17 -and -not $v.AccuracyPass)

    # Nearest-rank p95 and median; failed calls rank last.
    $rows = @(for ($i = 1; $i -le 20; $i++) { $r = New-FixtureResult $true ($i * 1000) '12.30'; Get-ScoredResult $truth $r })
    $v = Get-ModelVerdict $rows
    Assert-Case 'p95 nearest rank of 1..20 s -> 19000 ms' ($v.P95Ms -eq 19000)
    Assert-Case 'median nearest rank of 1..20 s -> 10000 ms' ($v.MedianMs -eq 10000)
    $rows = @(@($good) * 18) + @($err, $err)
    $v = Get-ModelVerdict $rows
    Assert-Case "p95 with 2 errors in 20 -> 'error'" ((Format-Ms $v.P95Ms) -eq 'error')

    # Date and store (reported only).
    Assert-Case 'date: exact yyyy-MM-dd -> match' (Test-DateMatch '2026-11-01' '2026-11-01')
    Assert-Case 'date: different day -> mismatch' (-not (Test-DateMatch '2026-11-01' '2026-11-02'))
    $zabka = "$([char]0x017B)abka"            # Z-dot-above + abka
    $lodzStore = "Sklep $([char]0x0141)$([char]0x00F3)d$([char]0x017A)"  # L-stroke, o-acute, z-acute
    Assert-Case 'store: case, whitespace and diacritics ignored' (Test-StoreMatch "  $zabka " 'ZABKA')
    Assert-Case 'store: l-stroke folded to l' (Test-StoreMatch $lodzStore 'sklep lodz')
    Assert-Case 'store: different name -> mismatch' (-not (Test-StoreMatch 'Example Market' 'Sample Store'))
    Assert-Case 'store: shop sign inside legal name -> match' (Test-StoreMatch 'Lidl' 'Lidl sp. z o.o. sp. k.')
    $stodola = "Stodo$([char]0x0142)a Market"                                  # Stodola Market, with l-stroke
    $spolemLong = """SPO$([char]0x0141)EM"" PSS STODO$([char]0x0141)A MARKET"  # "SPOLEM" PSS STODOLA MARKET
    $spolemShort = """SPO$([char]0x0141)EM"" PSS"
    Assert-Case 'store: quotes and punctuation ignored, contained -> match' (Test-StoreMatch $stodola $spolemLong)
    Assert-Case 'store: unrelated legal name -> mismatch' (-not (Test-StoreMatch $stodola $spolemShort))
    Assert-Case 'store: short name needs exact match' (-not (Test-StoreMatch 'AB' 'ABC Market'))
    Assert-Case 'store: both empty -> match' (Test-StoreMatch '' '')
    Assert-Case 'store: error row -> no match' (-not $err.StoreMatch)

    # Tokens, cost and backends.
    $v = Get-ModelVerdict @(New-FixtureRows 20 20 20) 5 25
    Assert-Case 'cost: 1000 in / 200 out at 5/25 per 1M -> 0.01 USD' ($v.CostPerReceipt -eq 0.01d -and $v.AvgInputTokens -eq 1000 -and $v.AvgOutputTokens -eq 200)
    Assert-Case 'backends: unique list' ($v.Backends.Count -eq 1 -and $v.Backends[0] -eq 'Fixture')
    $prices = ConvertFrom-PriceSpec 'claude=5/25, gpt=1.25/10'
    Assert-Case 'prices: parsed invariantly' ($prices['gpt'].In -eq 1.25d -and $prices['claude'].Out -eq 25)
    $threw = $false
    try { [void](ConvertFrom-PriceSpec 'claude=5,25') } catch { $threw = $true }
    Assert-Case 'prices: malformed entry rejected' $threw

    Write-Host ''
    if ($script:failures -gt 0) {
        Write-Host "Self-test: $($script:failures) case(s) failed."
        return 1
    }
    Write-Host 'Self-test: all cases passed.'
    return 0
}

if ($SelfTest) {
    exit (Invoke-SelfTest)
}

# ---------------------------------------------------------------------------------------------
# Preparation
# ---------------------------------------------------------------------------------------------

function Resolve-UserPath([string]$Path) {
    return [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
}

function Read-TruthFile([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        Stop-Spike "Receipts folder not found: $Dir"
    }
    $truthPath = Join-Path $Dir 'truth.csv'
    if (-not (Test-Path -LiteralPath $truthPath -PathType Leaf)) {
        Stop-Spike "Ground truth not found: $truthPath. Copy tools/extraction-spike/truth.example.csv there and fill it in."
    }

    # Read with an explicit header plus one spare column, so a row with an extra field (typically an
    # unquoted decimal comma such as 12,34) is reported instead of being silently cut to 12.
    $allRows = @(Import-Csv -LiteralPath $truthPath -Header 'file', 'store', 'date', 'total', 'extra')
    $headerOk = $false
    if ($allRows.Count -gt 0) {
        $h = $allRows[0]
        $names = @(([string]$h.file).TrimStart([char]0xFEFF), $h.store, $h.date, $h.total) | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() }
        $headerOk = ($names -join ',') -eq 'file,store,date,total' -and [string]::IsNullOrEmpty([string]$h.extra)
    }
    if (-not $headerOk) {
        $firstLine = Get-Content -LiteralPath $truthPath -TotalCount 1
        $hint = if ($firstLine -and $firstLine.Contains(';')) { ' The file uses semicolons; save it with commas.' } else { '' }
        Stop-Spike "truth.csv must start with the header file,store,date,total.$hint"
    }
    $rows = @($allRows | Select-Object -Skip 1)
    if ($rows.Count -eq 0) { Stop-Spike 'truth.csv has no receipt rows.' }

    $problems = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    $truth = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $line = $i + 2  # header is line 1
        $file = ([string]$rows[$i].file).Trim()
        if (-not [string]::IsNullOrEmpty([string]$rows[$i].extra)) {
            $problems.Add("line $line`: more than 4 fields. Use a dot in the total (12.34) and quote a store name that contains a comma.")
        }
        $date = ([string]$rows[$i].date).Trim()
        $total = ([string]$rows[$i].total).Trim()
        $label = if ($file) { "line $line ($file)" } else { "line $line" }

        if (-not $file) { $problems.Add("$label`: 'file' is empty."); continue }
        if ($seen.ContainsKey($file.ToLowerInvariant())) { $problems.Add("$label`: '$file' is listed twice.") }
        $seen[$file.ToLowerInvariant()] = $true

        $extension = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
        if ($extension -in '.heic', '.heif') {
            $problems.Add("$label`: '$file' is HEIC, which cannot be read. Export it as JPEG.")
        }
        elseif ($extension -notin '.jpg', '.jpeg') {
            $problems.Add("$label`: '$file' is not a JPEG (.jpg or .jpeg).")
        }
        elseif (-not (Test-Path -LiteralPath (Join-Path $Dir $file) -PathType Leaf)) {
            $problems.Add("$label`: photo '$file' not found in $Dir.")
        }

        if ($total -notmatch '^\d+(\.\d{1,2})?$') {
            $problems.Add("$label`: total '$total' must be a number with a dot and at most 2 decimals, for example 12.34.")
        }
        if ($date -ne '') {
            $parsedDate = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($date, 'yyyy-MM-dd', $Invariant, [System.Globalization.DateTimeStyles]::None, [ref]$parsedDate)) {
                $problems.Add("$label`: date '$date' must be yyyy-MM-dd or empty.")
            }
        }

        # A '?' or U+FFFD in a store name usually means the file was saved in a non-UTF-8 encoding
        # that dropped Polish letters (for example Windows PowerShell 5.1 '>' or Notepad as ANSI).
        $store = ([string]$rows[$i].store).Trim()
        if ($store.Contains('?') -or $store.Contains([string][char]0xFFFD)) {
            Write-Warning "$label`: store name '$store' looks mis-encoded (lost Polish letters?). Re-save truth.csv as UTF-8."
        }

        $truth.Add([pscustomobject]@{
            File  = $file
            Store = $store
            Date  = $date
            Total = $total
        })
    }

    if ($problems.Count -gt 0) {
        [Console]::Error.WriteLine("run-spike: truth.csv has $($problems.Count) problem(s); nothing was sent:")
        foreach ($p in $problems) { [Console]::Error.WriteLine("  - $p") }
        exit 1
    }

    $listed = @($truth | ForEach-Object { $_.File.ToLowerInvariant() })
    $unlisted = @(Get-ChildItem -LiteralPath $Dir -File | Where-Object {
            $_.Extension.ToLowerInvariant() -in '.jpg', '.jpeg' -and $listed -notcontains $_.Name.ToLowerInvariant()
        })
    foreach ($f in $unlisted) { Write-Warning "Photo '$($f.Name)' is not listed in truth.csv and is skipped." }

    return $truth.ToArray()
}

function Import-SystemDrawing {
    try {
        Add-Type -AssemblyName System.Drawing
        # Touch a type so a platform without GDI+ fails here, not halfway through the set.
        [void][System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders()
    }
    catch {
        Stop-Spike "System.Drawing could not be loaded ($($_.Exception.Message)). Run the script with PowerShell 7 on Windows."
    }
}

# Applies the EXIF orientation (System.Drawing does not), then resizes so the long edge is at most
# MaxLongEdge and saves as JPEG at JpegQuality.
function Convert-ReceiptPhoto([string]$Source, [string]$Destination) {
    $orientationTag = 0x0112
    $stream = [System.IO.File]::OpenRead($Source)
    try {
        $image = [System.Drawing.Image]::FromStream($stream, $true, $true)
        $output = $null
        try {
            if ($image.PropertyIdList -contains $orientationTag) {
                $orientation = [BitConverter]::ToUInt16($image.GetPropertyItem($orientationTag).Value, 0)
                $flip = switch ($orientation) {
                    2 { [System.Drawing.RotateFlipType]::RotateNoneFlipX }
                    3 { [System.Drawing.RotateFlipType]::Rotate180FlipNone }
                    4 { [System.Drawing.RotateFlipType]::Rotate180FlipX }
                    5 { [System.Drawing.RotateFlipType]::Rotate90FlipX }
                    6 { [System.Drawing.RotateFlipType]::Rotate90FlipNone }
                    7 { [System.Drawing.RotateFlipType]::Rotate270FlipX }
                    8 { [System.Drawing.RotateFlipType]::Rotate270FlipNone }
                    default { $null }
                }
                if ($null -ne $flip) { $image.RotateFlip($flip) }
                $image.RemovePropertyItem($orientationTag)
            }

            $longEdge = [Math]::Max($image.Width, $image.Height)
            $output = $image
            if ($longEdge -gt $MaxLongEdge) {
                $scale = $MaxLongEdge / $longEdge
                $width = [Math]::Max(1, [int][Math]::Round($image.Width * $scale))
                $height = [Math]::Max(1, [int][Math]::Round($image.Height * $scale))
                $output = [System.Drawing.Bitmap]::new($width, $height)
                $output.SetResolution($image.HorizontalResolution, $image.VerticalResolution)
                $graphics = [System.Drawing.Graphics]::FromImage($output)
                $attributes = [System.Drawing.Imaging.ImageAttributes]::new()
                try {
                    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                    $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                    # Avoids a faint dark border from sampling outside the source edges.
                    $attributes.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
                    $graphics.DrawImage($image, [System.Drawing.Rectangle]::new(0, 0, $width, $height),
                        0, 0, $image.Width, $image.Height, [System.Drawing.GraphicsUnit]::Pixel, $attributes)
                }
                finally {
                    $attributes.Dispose()
                    $graphics.Dispose()
                }
            }

            $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
            $encoderParams = [System.Drawing.Imaging.EncoderParameters]::new(1)
            try {
                $encoderParams.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new([System.Drawing.Imaging.Encoder]::Quality, [long]$JpegQuality)
                $output.Save($Destination, $codec, $encoderParams)
            }
            finally {
                $encoderParams.Dispose()
            }
            return [pscustomobject]@{ Width = $output.Width; Height = $output.Height }
        }
        finally {
            if ($null -ne $output -and -not [object]::ReferenceEquals($output, $image)) { $output.Dispose() }
            $image.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

# ---------------------------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------------------------

function Get-JsonProperties([System.Text.Json.JsonElement]$Element) {
    $map = @{}
    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        foreach ($p in $Element.EnumerateObject()) { $map[$p.Name] = $p.Value }
    }
    return $map
}

function Get-JsonValue([hashtable]$Map, [string]$Name, [string]$As = 'String') {
    if (-not $Map.ContainsKey($Name)) { return $null }
    $el = $Map[$Name]
    switch ($el.ValueKind) {
        ([System.Text.Json.JsonValueKind]::Null) { return $null }
        ([System.Text.Json.JsonValueKind]::Number) {
            switch ($As) {
                'Decimal' { return $el.GetDecimal() }
                'Long' { return $el.GetInt64() }
                default { return $el.GetRawText() }
            }
        }
        ([System.Text.Json.JsonValueKind]::String) {
            $text = $el.GetString()
            if ($As -eq 'Decimal') { return ConvertTo-InvariantDecimal $text }
            if ($As -eq 'Long') { $n = [long]0; if ([long]::TryParse($text, [ref]$n)) { return $n } else { return $null } }
            return $text
        }
        default { return $el.GetRawText() }
    }
}

function Get-ErrorDetail([string]$Body) {
    if ([string]::IsNullOrWhiteSpace($Body)) { return '' }
    try {
        $doc = [System.Text.Json.JsonDocument]::Parse($Body)
        try {
            $map = Get-JsonProperties $doc.RootElement
            $detail = Get-JsonValue $map 'detail'
            if (-not $detail) { $detail = Get-JsonValue $map 'title' }
            if ($detail) { return $detail }
        }
        finally { $doc.Dispose() }
    }
    catch { }
    $flat = ($Body -replace '\s+', ' ').Trim()
    if ($flat.Length -gt 300) { $flat = $flat.Substring(0, 300) + '...' }
    return $flat
}

# One call to the extraction endpoint. Ms is the wall-clock time of the whole HTTP call (send the
# photo, receive and buffer the full response); parsing happens after the clock stops.
function Invoke-Extraction([System.Net.Http.HttpClient]$Client, [string]$Alias, [string]$PhotoPath) {
    $url = "$($ApiBase.TrimEnd('/'))/api/dev/receipts/extract?model=$([Uri]::EscapeDataString($Alias))"
    $bytes = [System.IO.File]::ReadAllBytes($PhotoPath)
    $form = [System.Net.Http.MultipartFormDataContent]::new()
    $part = [System.Net.Http.ByteArrayContent]::new($bytes)
    $part.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('image/jpeg')
    $form.Add($part, 'photo', [System.IO.Path]::GetFileName($PhotoPath))

    $status = ''
    $body = $null
    $errorText = ''
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $response = $Client.PostAsync($url, $form).GetAwaiter().GetResult()
        try {
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $stopwatch.Stop()
            $status = ([int]$response.StatusCode).ToString($Invariant)
        }
        finally { $response.Dispose() }
    }
    catch {
        $stopwatch.Stop()
        $isTimeout = $false
        $ex = $_.Exception
        $messages = [System.Collections.Generic.List[string]]::new()
        while ($null -ne $ex) {
            if ($ex -is [System.TimeoutException] -or $ex -is [System.Threading.Tasks.TaskCanceledException]) { $isTimeout = $true }
            if ($ex -isnot [System.Management.Automation.MethodInvocationException]) { $messages.Add($ex.Message) }
            $ex = $ex.InnerException
        }
        if ($isTimeout) {
            $status = 'timeout'
            $errorText = "No response within $ClientTimeoutSeconds s."
        }
        else {
            $status = 'no-response'
            $errorText = ($messages | Select-Object -Unique) -join ' / '
        }
    }
    finally {
        $form.Dispose()
    }

    $result = [ordered]@{
        Alias = $Alias; Status = $status; Ok = $false; Ms = [long]$stopwatch.ElapsedMilliseconds
        ProviderMs = $null; Model = $null; ServedBy = $null; InputTokens = $null; OutputTokens = $null
        Store = $null; PurchaseDate = $null; Currency = $null; Total = $null; ItemCount = $null; Error = $errorText
    }

    if ($status -eq '200') {
        try {
            $doc = [System.Text.Json.JsonDocument]::Parse($body)
            try {
                $map = Get-JsonProperties $doc.RootElement
                $result.Store = Get-JsonValue $map 'store'
                $result.PurchaseDate = Get-JsonValue $map 'purchaseDate'
                $result.Currency = Get-JsonValue $map 'currency'
                $result.Total = Get-JsonValue $map 'total' 'Decimal'
                $result.Model = Get-JsonValue $map 'model'
                $result.ServedBy = Get-JsonValue $map 'servedBy'
                $result.ProviderMs = Get-JsonValue $map 'providerMs' 'Long'
                $result.InputTokens = Get-JsonValue $map 'inputTokens' 'Long'
                $result.OutputTokens = Get-JsonValue $map 'outputTokens' 'Long'
                if ($map.ContainsKey('items') -and $map['items'].ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
                    $result.ItemCount = $map['items'].GetArrayLength()
                }
                $result.Ok = $true
            }
            finally { $doc.Dispose() }
        }
        catch {
            $result.Status = '200-unreadable'
            $result.Error = "The 200 response could not be read as JSON: $($_.Exception.Message)"
        }
    }
    elseif ($status -notin 'timeout', 'no-response') {
        $result.Error = Get-ErrorDetail $body
    }

    return [pscustomobject]$result
}

# ---------------------------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------------------------

function Format-Invariant($Value) {
    if ($null -eq $Value) { return '' }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    if ($Value -is [System.IFormattable]) { return $Value.ToString($null, $Invariant) }
    return [string]$Value
}

function Write-ResultsCsv([object[]]$Rows, [string]$Path) {
    $columns = 'File', 'Alias', 'Model', 'ServedBy', 'Status', 'Ok', 'Ms', 'ProviderMs', 'WithinLimit',
        'TruthTotal', 'Total', 'TotalMatch', 'TruthDate', 'PurchaseDate', 'DateMatch',
        'TruthStore', 'Store', 'StoreMatch', 'Currency', 'ItemCount', 'InputTokens', 'OutputTokens', 'Error'
    $out = foreach ($r in $Rows) {
        $o = [ordered]@{}
        foreach ($c in $columns) { $o[$c] = Format-Invariant $r.$c }
        [pscustomobject]$o
    }
    @($out) | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8
}

function Format-Mark([bool]$Value) { if ($Value) { $Tick } else { $Cross } }

function Format-Count([int]$Count, [int]$N) { "$Count / $N" }

# The committed report: aggregates and per-file marks only. No store names, dates or amounts.
function Write-Report([string]$Path, [object[]]$Truth, [string[]]$Aliases, [hashtable]$RowsByAlias,
    [hashtable]$Verdicts, [hashtable]$Slugs, [hashtable]$PriceTable, [datetime]$StartedAt) {
    $n = $Truth.Count
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Extraction provider spike report')
    $lines.Add('')
    $lines.Add('Generated by `tools/extraction-spike/run-spike.ps1`. Do not edit by hand; re-run the script instead.')
    $lines.Add('')
    $lines.Add("- Run date: $($StartedAt.ToString('yyyy-MM-dd HH:mm', $Invariant)) (local time)")
    $lines.Add("- Receipts (N): $n")
    foreach ($a in $Aliases) { $lines.Add("- Model ``$a``: ``$($Slugs[$a])``") }
    $lines.Add("- Latency is wall-clock per HTTP call from this machine to ``$ApiBase`` (includes OpenRouter), client timeout $ClientTimeoutSeconds s, after one untimed warm-up call per model. Photos are resized to a long edge of $Le $MaxLongEdge px, JPEG quality $JpegQuality, before timing.")
    $lines.Add("- Latency PASS: calls $Le 10,000 ms $([char]0x2265) ceil(0.95 $([char]0x00D7) N). Accuracy PASS: exact totals $([char]0x2265) ceil(0.9 $([char]0x00D7) N). Errors and timeouts count as over 10 s and as a total mismatch. p95 and median are nearest-rank; 'error' means that rank fell on a failed call.")
    $lines.Add('')

    foreach ($a in $Aliases) {
        $v = $Verdicts[$a]
        $avgIn = if ($null -eq $v.AvgInputTokens) { 'n/a' } else { ([long][Math]::Round($v.AvgInputTokens)).ToString($Invariant) }
        $avgOut = if ($null -eq $v.AvgOutputTokens) { 'n/a' } else { ([long][Math]::Round($v.AvgOutputTokens)).ToString($Invariant) }
        $cost = if ($null -eq $v.CostPerReceipt) { 'n/a' } else {
            $p = $PriceTable[$a]
            "$([decimal]::Round($v.CostPerReceipt, 5).ToString('0.00000', $Invariant)) USD (at $($p.In.ToString($Invariant)) / $($p.Out.ToString($Invariant)) USD per 1M input / output tokens)"
        }
        $backends = if ($v.Backends.Count -gt 0) { $v.Backends -join ', ' } else { 'none reported' }

        $lines.Add("## ``$a`` ($($Slugs[$a]))")
        $lines.Add('')
        $lines.Add('| Metric | Value |')
        $lines.Add('| --- | --- |')
        $lines.Add("| Calls $Le 10 s | $(Format-Count $v.Within $n) (need $($v.LatencyNeeded)) |")
        $lines.Add("| p95 ms | $(Format-Ms $v.P95Ms) |")
        $lines.Add("| Median ms | $(Format-Ms $v.MedianMs) |")
        $lines.Add("| Exact totals | $(Format-Count $v.Exact $n) (need $($v.AccuracyNeeded)) |")
        $lines.Add("| Date matches | $(Format-Count $v.DateMatches $n) |")
        $lines.Add("| Store matches | $(Format-Count $v.StoreMatches $n) |")
        $lines.Add("| Errors | $($v.Errors) |")
        $lines.Add("| Backends seen | $backends |")
        $lines.Add("| Average input / output tokens | $avgIn / $avgOut |")
        $lines.Add("| Cost per receipt | $cost |")
        $lines.Add("| **Latency** | **$(if ($v.LatencyPass) { 'PASS' } else { 'FAIL' })** |")
        $lines.Add("| **Accuracy** | **$(if ($v.AccuracyPass) { 'PASS' } else { 'FAIL' })** |")
        $lines.Add('')
    }

    $lines.Add('## Per receipt')
    $lines.Add('')
    $lines.Add("$Tick = rule met, $Cross = not met. A failed call shows its status next to the latency mark.")
    $lines.Add('')
    $header = '| File |'
    $rule = '| --- |'
    foreach ($a in $Aliases) {
        $header += " $a $Le 10 s | $a total | $a date | $a store |"
        $rule += ' :-: | :-: | :-: | :-: |'
    }
    $lines.Add($header)
    $lines.Add($rule)
    foreach ($t in $Truth) {
        $line = "| $($t.File) |"
        foreach ($a in $Aliases) {
            $r = $RowsByAlias[$a] | Where-Object { $_.File -eq $t.File } | Select-Object -First 1
            $latency = Format-Mark $r.WithinLimit
            if (-not $r.Ok) { $latency += " ($($r.Status))" }
            $line += " $latency | $(Format-Mark $r.TotalMatch) | $(Format-Mark $r.DateMatch) | $(Format-Mark $r.StoreMatch) |"
        }
        $lines.Add($line)
    }

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    [System.IO.File]::WriteAllText($Path, ($lines -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
}

# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------

$ReceiptsDir = Resolve-UserPath $ReceiptsDir
$ReportPath = Resolve-UserPath $ReportPath
$OutDir = Resolve-UserPath $OutDir

$aliases = @($Models.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
if ($aliases.Count -eq 0) { Stop-Spike '-Models is empty. Pass aliases such as "claude,gpt".' }
foreach ($a in $aliases) {
    if ($a -notmatch '^[A-Za-z0-9_-]+$') { Stop-Spike "Model alias '$a' may only contain letters, digits, '-' and '_'." }
}

try { $priceTable = ConvertFrom-PriceSpec $Prices } catch { Stop-Spike $_.Exception.Message }
foreach ($key in @($priceTable.Keys)) {
    if ($aliases -notcontains $key) { Write-Warning "Price given for '$key', which is not in -Models; ignored." }
}

# Validation needs neither the API nor System.Drawing, so a bad truth.csv fails fast.
$truth = Read-TruthFile $ReceiptsDir
Write-Host "Ground truth: $($truth.Count) receipt(s) in $ReceiptsDir"

Import-SystemDrawing
$resizedDir = Join-Path $OutDir 'resized'
[void](New-Item -ItemType Directory -Path $resizedDir -Force)
$photoPaths = @{}
foreach ($t in $truth) {
    $destination = Join-Path $resizedDir ([System.IO.Path]::ChangeExtension($t.File, '.jpg'))
    try {
        $size = Convert-ReceiptPhoto (Join-Path $ReceiptsDir $t.File) $destination
    }
    catch {
        Stop-Spike "Could not prepare '$($t.File)': $($_.Exception.Message)"
    }
    $photoPaths[$t.File] = $destination
    Write-Host ("Prepared {0} -> {1}x{2}" -f $t.File, $size.Width, $size.Height)
}

$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds($ClientTimeoutSeconds)
$startedAt = Get-Date
$rowsByAlias = @{}
foreach ($a in $aliases) { $rowsByAlias[$a] = [System.Collections.Generic.List[object]]::new() }
$resultsPath = Join-Path $OutDir 'results.csv'

try {
    # Warm-up: untimed, one per model. Stop on answers that mean the run cannot succeed.
    $warmupPhoto = $photoPaths[$truth[0].File]
    foreach ($a in $aliases) {
        $w = Invoke-Extraction $client $a $warmupPhoto
        Write-Host "Warm-up $a`: $($w.Status) in $($w.Ms) ms"
        if ($w.Status -eq 'no-response') {
            Stop-Spike "The API at $ApiBase did not answer ($($w.Error)). Start it with: dotnet run --project src/Expify.Api (http profile)."
        }
        if ($w.Status -in '400', '404', '503') {
            Stop-Spike "Warm-up for '$a' returned $($w.Status): $($w.Error)"
        }
        if (-not $w.Ok) { Write-Warning "Warm-up for '$a' failed ($($w.Status)): $($w.Error). Continuing." }
    }

    $index = 0
    foreach ($t in $truth) {
        $index++
        foreach ($a in $aliases) {
            $raw = Invoke-Extraction $client $a $photoPaths[$t.File]
            $raw | Add-Member -NotePropertyName File -NotePropertyValue $t.File
            $scored = Get-ScoredResult $t $raw
            $rowsByAlias[$a].Add($scored)
            $note = if ($scored.Ok) { '' } else { " - $($scored.Error)" }
            Write-Host ("[{0}/{1}] {2} {3}: {4} {5} ms, {6} 10 s {7}, total {8}{9}" -f $index, $truth.Count, $t.File, $a,
                $scored.Status, $scored.Ms, $Le, (Format-Mark $scored.WithinLimit), (Format-Mark $scored.TotalMatch), $note)
        }
        # Rewritten after every receipt so an interrupted run keeps what it measured.
        $all = @(foreach ($a in $aliases) { $rowsByAlias[$a] })
        Write-ResultsCsv $all $resultsPath
    }
}
finally {
    $client.Dispose()
}

$verdicts = @{}
$slugs = @{}
foreach ($a in $aliases) {
    $price = $priceTable[$a]
    $inPrice = if ($price) { $price.In } else { $null }
    $outPrice = if ($price) { $price.Out } else { $null }
    $verdicts[$a] = Get-ModelVerdict $rowsByAlias[$a].ToArray() $inPrice $outPrice
    $firstOk = $rowsByAlias[$a] | Where-Object { $_.Ok -and $_.Model } | Select-Object -First 1
    $slugs[$a] = if ($firstOk) { $firstOk.Model } else { $a }
}

Write-Report $ReportPath $truth $aliases $rowsByAlias $verdicts $slugs $priceTable $startedAt

Write-Host ''
foreach ($a in $aliases) {
    $v = $verdicts[$a]
    Write-Host ("{0}: latency {1} ({2}/{3}, p95 {4} ms), accuracy {5} ({6}/{3})" -f $a,
        $(if ($v.LatencyPass) { 'PASS' } else { 'FAIL' }), $v.Within, $v.N, (Format-Ms $v.P95Ms),
        $(if ($v.AccuracyPass) { 'PASS' } else { 'FAIL' }), $v.Exact)
}
Write-Host "Results (private): $resultsPath"
Write-Host "Report: $ReportPath"
exit 0
