# Extraction provider spike

Tools for the `extraction-provider-spike` change: compare AI models on real receipts through the
Development-only endpoint `POST /api/dev/receipts/extract?model=<alias>`. See
`context/changes/extraction-provider-spike/plan.md` for the rules and phases.

The `receipts/` and `out/` folders are git-ignored. Receipt photos, the typed ground truth and raw
results stay on your machine and are never committed.

## 1. Set up OpenRouter privacy before the first call

Do this before sending any receipt photo:

1. Create an OpenRouter account and add credit.
2. In the account's privacy settings, turn prompt and response logging off.
3. In the same settings, exclude providers that may train on inputs.
4. Create an API key and store it in user secrets (never in `appsettings*.json`):

   ```bash
   dotnet user-secrets set "Extraction:OpenRouter:ApiKey" "<your key>" --project src/Expify.Api
   ```

5. Check that the model slugs in `src/Expify.Api/appsettings.Development.json`
   (`Extraction:OpenRouter:Models`) match current models on <https://openrouter.ai/models>.

## 2. Prepare the receipts

1. Photograph 20 real receipts as **JPEG** (not HEIC). On an iPhone, set Camera > Formats to
   "Most Compatible", or export the photos as JPEG.
2. Put the photos in `tools/extraction-spike/receipts/`.
3. Copy the example ground truth into that folder:

   ```bash
   cp tools/extraction-spike/truth.example.csv tools/extraction-spike/receipts/truth.csv
   ```

4. Replace the example rows with one row per photo, typed from the paper receipt:
   - `file`: the photo's file name, for example `receipt-01.jpg`
   - `store`: the store name as printed
   - `date`: the purchase date as `yyyy-MM-dd`
   - `total`: the printed total, with a dot as the decimal separator, for example `12.34`

## 3. Run the API

Run the API in Development with the `http` launch profile:

```bash
dotnet run --project src/Expify.Api
```

Keep the `http` profile (the default above, `http://localhost:5066`).

## 4. Running the spike

From the repository root, in a second terminal, with PowerShell 7 on Windows:

```powershell
pwsh -NoProfile -File tools/extraction-spike/run-spike.ps1 -Prices "claude=5/25,gpt=1.25/10"
```

- `-Prices` is optional: `alias=input/output`, in USD per 1M input and output tokens, with a dot
  as the decimal separator, copied from each model's OpenRouter page. Without it, cost shows `n/a`.
- Other parameters (defaults in brackets): `-ReceiptsDir` (`tools/extraction-spike/receipts`),
  `-ApiBase` (`http://localhost:5066`), `-Models` (`claude,gpt`), `-ReportPath`
  (`context/changes/extraction-provider-spike/spike-report.md`), `-OutDir`
  (`tools/extraction-spike/out`).
- For a dry run, point `-ReceiptsDir` at a folder with 2 photos and its own `truth.csv`, and
  `-ReportPath` at a file outside `context/` so the real report is not overwritten.

What the script does:

1. Checks `truth.csv` first and stops, sending nothing, if a photo is missing, not a JPEG, or a
   total or date has the wrong format.
2. Applies each photo's EXIF orientation and resizes it to a long edge of at most 2000 px (JPEG
   quality 85) into `out/resized/`.
3. Sends one untimed warm-up call per model, then each receipt to each model in turn, with a 60 s
   timeout. Each send costs OpenRouter credit, warm-up calls included.
4. Writes `out/results.csv` with every returned value and error (private, git-ignored) and the
   report at `-ReportPath`. The report holds only counts, PASS/FAIL and per-file marks, never store
   names, dates or amounts. File names do appear in it, so name photos `receipt-01.jpg` and so on,
   not after the store.

Check the scoring rules without any photos or API calls:

```powershell
pwsh -NoProfile -File tools/extraction-spike/run-spike.ps1 -SelfTest
```

It exits with code 0 when every built-in case passes and 1 otherwise.
