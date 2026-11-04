# First deploy: Expify → Azure App Service (Linux B1, Poland Central)

## Context

`context/foundation/infrastructure.md` picked Azure App Service (Linux B1, Poland Central). The SPA is served from the API's `wwwroot` on one origin, and CI runs on GitHub Actions with OIDC. The repo is still the scaffold: `Program.cs` has only `/weatherforecast`, there is no `.github/workflows/`, and neither `az` nor `gh` is installed. The goal of this change is to prove the deploy path end to end, so that every later feature merges to `master` and ships automatically.

Decisions made with the user:
- **Runtime:** `DOTNETCORE:9.0` now. .NET 9 support ends 2026-11-10, so the .NET 10 upgrade is the first follow-up change.
- **Scope:** App Service and CI only. Azure SQL and Blob come with the feature that needs them.
- **Manual gates:** the user installs the CLIs, creates Azure resources and sets up OIDC. The agent writes code and the workflow, and runs read-only verification.
- **No `gh` CLI (2026-11-04):** `gh` cannot be installed on this machine. Every GitHub action (secrets, variables, push, watching runs, re-running, rollback) is done by the user by hand in the github.com web UI or with plain `git`. The agent never calls `gh` and never pushes.

Each phase has checkboxes. Mark [x] as it completes.

**Status (2026-11-04, update 2):** Phases 1 and 2 done. `az` is signed in (subscription "Azure subscription 1"). `gh` is dropped from the plan; GitHub steps are manual in the web UI. Web app `expify-adr` (`https://expify-adr.azurewebsites.net`) exists with the planned settings but still serves the default App Service page, so Phase 3 is next. `app.zip` is built and checked. **Update 3:** first deploy is live at `https://expify-adr.azurewebsites.net` through CI (commit `cb1d939`). Phase 3 was skipped. Phases 4, 5 and 6 are done, and the end-to-end checks pass. Open items: commit and push these docs, delete the unused `gh-master` credential, and start the .NET 10 upgrade before 2026-11-10.

---

## Phase 0: Prerequisites (USER, manual)

- [x] Install the Azure CLI: `winget install -e --id Microsoft.AzureCLI`, then open a new terminal. (`gh` is not used; see "No `gh` CLI" above.)
- [x] Sign in with `az login` (pick the right subscription with `az account set -s <id>`).
- [ ] Confirm you can sign in to github.com as an admin of `AdamDratwa/Expify` (needed for Settings → Secrets and variables) and that `git push` to `origin` works from this machine.
- [x] Check the runtime: `az webapp list-runtimes --os linux | Select-String DOTNETCORE` must list `DOTNETCORE:9.0`. Write down whether `10.0` is listed too; the follow-up change needs it. (2026-11-04: `DOTNETCORE|9.0` EOL 2026-11-10, `DOTNETCORE|10.0` LTS available.)
- [x] Check B1 quota in Poland Central (portal → Quotas → App Service). **Edge case:** if quota is 0 or `plan create` fails with a quota error, use `-l westeurope` everywhere in Phase 2.

## Phase 1: Code changes (AGENT)

- [x] **`src/Expify.Api/Program.cs`**
  - Configure `ForwardedHeadersOptions` with `XForwardedFor | XForwardedProto`, and clear `KnownNetworks` and `KnownProxies`. This is required on App Service Linux because the front end's IP is not loopback. Call `app.UseForwardedHeaders()` first in the pipeline.
  - Keep `UseHttpsRedirection()`, which now sees the correct scheme.
  - Add `app.UseDefaultFiles()` and `app.UseStaticFiles()`.
  - Add `app.MapGet("/api/health", () => Results.Ok(new { status = "ok" }))`. This is the smoke-test endpoint, kept under `/api` per the hard rule.
  - Add `app.MapFallbackToFile("index.html")` as the last mapping, so Angular deep links work.
  - **Edge case:** an unknown `/api/*` path must not fall back to `index.html`. Map `app.MapFallback("/api/{**rest}", () => Results.NotFound())` before the SPA fallback.
- [x] **`.gitignore`**: add `src/Expify.Api/wwwroot/`, since it is generated from the Angular build, and `app.zip`.
- [x] **`.github/workflows/deploy.yml`**: new file.
  - Triggers: `push` on `master`, `pull_request` on `master` (build and test only), and `workflow_dispatch`.
  - **build job** (ubuntu-latest):
    - `actions/setup-dotnet@v4` with `global-json-file: global.json`, and `actions/setup-node@v4` with Node 26 and npm cache on `src/Expify.Web/package-lock.json`.
    - In `src/Expify.Web`: `npm ci`, then `npx ng test --watch=false`, then `npm run build`.
    - `mkdir -p src/Expify.Api/wwwroot && cp -r src/Expify.Web/dist/expify-web/browser/. src/Expify.Api/wwwroot/`
    - `dotnet publish src/Expify.Api -c Release -o publish`
    - **Guard:** fail if `publish/wwwroot/index.html` is missing.
    - `actions/upload-artifact@v4`: the `publish/` folder, named `app-${{ github.sha }}`, `retention-days: 90`. This artifact is the rollback source.
  - **deploy job:**
    - Runs with `needs: build` and `if: github.event_name != 'pull_request'`.
    - `permissions: id-token: write, contents: read`.
    - `concurrency: deploy-production` with `cancel-in-progress: false`.
    - Steps: download the artifact, `azure/login@v2` (client-id, tenant-id and subscription-id from secrets), then `azure/webapps-deploy@v3` with `app-name: ${{ vars.AZURE_WEBAPP_NAME }}` and `package: publish`.
    - **No `environment:` key.** Adding one would change the OIDC subject to `environment:…` and break the `ref:refs/heads/master` federated credential.
    - Final step: smoke test with `curl --fail --retry 10 --retry-delay 10 https://${{ vars.AZURE_WEBAPP_NAME }}.azurewebsites.net/api/health`.
- [x] **Local check** (2026-11-04: build OK, 2/2 tests pass, `/` 200, deep link 200 → index.html, `/api/health` 200, `/api/nope` 404): `dotnet build Expify.sln`, `npm run build`, and `npx ng test --watch=false`. Copy `dist` into `wwwroot`, run `dotnet run --project src/Expify.Api` (http profile), then confirm that `/`, `/some/deep/link`, `/api/health` and `/api/nope` (404) all behave as described above.

## Phase 2: Create Azure resources (USER, manual, one-time)

Pick `<app>` as a globally unique name, for example `expify-adr`.

```powershell
az group create -n rg-expify -l polandcentral
az appservice plan create -g rg-expify -n asp-expify --is-linux --sku B1
az webapp create -g rg-expify -p asp-expify -n <app> --runtime "DOTNETCORE:9.0"
az webapp config set -g rg-expify -n <app> --always-on true --http20-enabled true --min-tls-version 1.2
az webapp update -g rg-expify -n <app> --client-affinity-enabled false --https-only true
az webapp config appsettings set -g rg-expify -n <app> --settings SCM_DO_BUILD_DURING_DEPLOYMENT=false
az webapp log config -g rg-expify -n <app> --docker-container-logging filesystem
```
- [x] Resources created. (Verified 2026-11-04: `expify-adr` in `rg-expify`, Poland Central, plan `asp-expify` B1, `DOTNETCORE|9.0`, Always On, HTTPS only, HTTP/2, TLS 1.2, ARR affinity off, empty startup command, `SCM_DO_BUILD_DURING_DEPLOYMENT` set.)
- [x] **Budget:** in the portal, set a budget on `rg-expify` of $20/month with an alert at 80%. `az consumption budget` is unreliable, so use the portal. (Budget `consumption_budget`, $20 monthly, exists.)
- [x] **Edge case:** if the runtime string is rejected, run `az webapp list-runtimes --os linux` and use the exact string from the list, for example `DOTNETCORE|9.0` in older CLI versions.

## Phase 3: First manual deploy (USER runs, AGENT prepares the zip)

- [x] AGENT: build the frontend, copy it into `wwwroot`, then run `dotnet publish src/Expify.Api -c Release -o publish` and `Compress-Archive -Path publish/* -DestinationPath app.zip -Force`. This needs PowerShell 7, whose zip entries use forward slashes, which Linux needs.
- [-] USER: `az webapp deploy -g rg-expify -n expify-adr --src-path app.zip --type zip`. **Skipped:** the user pushed straight to `master`, and the first successful CI run did the first deploy.
- [x] Verify: `https://<app>.azurewebsites.net/api/health` returns `{"status":"ok"}`, `/` shows the Angular placeholder, and a deep link returns `index.html`. (Covered by the end-to-end checks after the CI deploy.)
- [-] **Edge case:** if the site shows the default App Service page or a 500, run `az webapp log tail -g rg-expify -n <app>`. Check that the startup command is empty (App Service auto-detects `Expify.Api.dll`). If it isn't detected, run `az webapp config set --startup-file "dotnet Expify.Api.dll"`.

## Phase 4: GitHub OIDC (USER, manual)

```powershell
$app = az ad app create --display-name gh-expify-deploy | ConvertFrom-Json
az ad sp create --id $app.appId
$webappId = az webapp show -g rg-expify -n <app> --query id -o tsv
az role assignment create --assignee $app.appId --role "Website Contributor" --scope $webappId
@'
{"name":"gh-master","issuer":"https://token.actions.githubusercontent.com","subject":"repo:AdamDratwa/Expify:ref:refs/heads/master","audiences":["api://AzureADTokenExchange"]}
'@ | Set-Content fic.json
az ad app federated-credential create --id $app.appId --parameters fic.json; Remove-Item fic.json
# Print the values to paste into GitHub:
"AZURE_CLIENT_ID       = $($app.appId)"
"AZURE_TENANT_ID       = $(az account show --query tenantId -o tsv)"
"AZURE_SUBSCRIPTION_ID = $(az account show --query id -o tsv)"
```
- [x] Azure side done (app registration, service principal, role assignment, federated credential). (Verified 2026-11-04: one registration `gh-expify-deploy`, appId `1f6879fe-14d3-4a88-b340-7e5f7c86dffc`; service principal exists; `Website Contributor` scoped to `expify-adr` only; federated credential `gh-master` with subject `repo:AdamDratwa/Expify:ref:refs/heads/master`; 0 client secrets.)
- [x] **Subject format fix (2026-11-04).** The first CI run failed at `azure/login` with `AADSTS700213`. GitHub sends a subject with numeric owner and repo IDs: `repo:AdamDratwa@22412061/Expify@1444649362:ref:refs/heads/master`. The user added a second federated credential, `gh-master-ids`, with exactly that subject, and the re-run passed. **Any future federated credential for this repo must use the `owner@22412061/repo@1444649362` form.** The old `gh-master` credential matches nothing and can be deleted with `az ad app federated-credential delete --id 1f6879fe-14d3-4a88-b340-7e5f7c86dffc --federated-credential-id gh-master`.
- [x] **GitHub side, by hand in the web UI:** open `https://github.com/AdamDratwa/Expify/settings/secrets/actions`.
  - **Secrets** tab → "New repository secret", three times: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, with the values printed above.
  - **Variables** tab → "New repository variable": `AZURE_WEBAPP_NAME` = `expify-adr`.
  - Use repository-level secrets, not environment secrets (the workflow has no `environment:` key).
- [x] Check: the Secrets tab lists the three names and the Variables tab lists `AZURE_WEBAPP_NAME`. Names are case-sensitive and must match `deploy.yml` exactly.
- [ ] **Edge case:** `workflow_dispatch` runs on `master` match the same subject. Runs from other branches fail `azure/login` by design.
- [ ] **Edge case:** if `azure/webapps-deploy` returns 403, the role assignment may not have propagated yet. Wait 5 minutes and re-run.

## Phase 5: CI deploy (AGENT commits locally, USER pushes and watches)

- [x] Phase 1 changes committed on `master` as `cb1d939 first deploy`. The user made the commit.
- [x] USER: `git push origin master`.
- [x] USER verifies in the web UI: `https://github.com/AdamDratwa/Expify/actions` → the "deploy" run for the pushed commit → both `build` and `deploy` jobs green, including the smoke-test step. (The first attempt failed at `azure/login`; see the subject format fix in Phase 4. The re-run was green.)
- [x] AGENT re-runs the end-to-end checks below with `curl`/`az` (read-only). (2026-11-04: checks 1–6 pass.)
- [ ] Rollback drill (document only, both by hand):
  - Web UI: Actions → the last good run → "Re-run all jobs".
  - Or: open the last good run → Artifacts → download `app-<sha>`, unzip, re-zip the contents with `Compress-Archive -Path publish/* -DestinationPath app.zip -Force`, and run `az webapp deploy -g rg-expify -n expify-adr --src-path app.zip --type zip`.

## Phase 6: Record and documentation (AGENT)

- [x] Write this plan, with checkbox states, app name (`expify-adr`) and URL (`https://expify-adr.azurewebsites.net`), to `context/deployment/deploy-plan.md`. That is the path `CLAUDE.md` names as the downstream ground truth.
- [x] `README.md`: change Hosting and CI/CD from "(planned)" to live, add the URL, and add a short "Deploy" section covering the workflow, rollback (via the Actions web UI, not `gh`) and `az webapp log tail`.
- [x] `AGENTS.md`: note that `src/Expify.Api/wwwroot/` is generated by CI and must not be committed. (Also added: pushing to `master` deploys and is user-only; no `environment:` key; the ID-based OIDC subject.)
- [ ] Follow-up, not done here: open the change "Upgrade to .NET 10" (global.json, csproj, AGENTS.md hard rule, tech-stack.md, `--runtime DOTNETCORE:10.0`).

## Verification (end to end)

Result on 2026-11-04 after the CI deploy of `cb1d939`: 1 → 200 `{"status":"ok"}`; 2 → 200, title `ExpifyWeb`, has `<app-root>`; 3 → 200 `index.html`; 4 → 404; 5 → 301 to `https://expify-adr.azurewebsites.net/`; 6 → `Running`, Always On, HTTPS only; 7 → green per the user.

1. `curl -i https://<app>.azurewebsites.net/api/health` returns 200 JSON.
2. `curl -i https://<app>.azurewebsites.net/` returns 200 HTML with the Angular `<app-root>`.
3. `curl -i https://<app>.azurewebsites.net/receipts/123` returns 200 `index.html` (SPA fallback).
4. `curl -i https://<app>.azurewebsites.net/api/nope` returns 404.
5. `curl -i http://<app>.azurewebsites.net/` returns a 301 redirect to https.
6. `az webapp show -g rg-expify -n <app> --query "{state:state, alwaysOn:siteConfig.alwaysOn, httpsOnly:httpsOnly}"`
7. A green GitHub Actions run on `master`, with the artifact retained (checked by the user in the Actions web UI).

## Critical files
- `src/Expify.Api/Program.cs` (modify)
- `.github/workflows/deploy.yml` (new)
- `.gitignore`, `README.md`, `AGENTS.md` (modify)
- `context/deployment/deploy-plan.md` (new)
