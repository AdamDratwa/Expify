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

The replay and scoring script is added in a later phase of the change.
