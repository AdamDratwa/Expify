---
project: Expify
researched_at: 2026-11-03
recommended_platform: Azure App Service (Linux, B1, Poland Central)
runner_up: Azure Container Apps
context_type: mvp
tech_stack:
  language: C# (API), TypeScript (frontend)
  framework: ASP.NET Core Web API + Angular 22 SPA
  runtime: .NET 9 (end of support 2026-11-10; .NET 10 LTS upgrade recommended, see Risk Register)
---

## Recommendation

**Deploy on Azure App Service (Linux, B1 plan, Poland Central), with the Angular build served from the API's `wwwroot` on a single origin, Azure SQL Database (free offer) for data and Azure Blob Storage for receipt photos.**

App Service is the only shortlisted platform that runs .NET natively with no Dockerfile or container registry. It passes four of the five agent-friendly criteria outright. It also fits every interview answer: the developer already knows Azure (familiarity), the app is request/response only (no persistent connections), a single EU region is enough (Poland Central), and the database and photo storage come from the same vendor (co-location preferred). On B1 with Always On, the app never starts cold, which protects the 10-second extraction budget. That costs about $13/month, a fair trade given cost and DX were weighted equally.

## Platform Comparison

Hard filters were applied first. The interview answer "no persistent connections" removed none. The .NET runtime requirement removed **Netlify**: its functions run TS/JS/Go only and it has no container runtime.

| Platform | CLI-first | Managed/Serverless | Agent-readable docs | Stable deploy API | MCP / Integration | Total (P=1, ½=Partial) | Weighted fit |
|---|---|---|---|---|---|---|---|
| **Azure App Service** | Pass | Pass | Pass | Pass | Partial | 4.5 | **Highest**: familiarity, co-location, Poland Central, no container needed |
| Azure Container Apps | Pass | Pass | Pass | Partial | Pass | 4.5 | High: same Azure services; adds ACR + cold start |
| Railway | Pass | Pass | Pass | Partial | Partial | 4.0 | Medium: Postgres + Buckets co-located; Dockerfile required |
| Cloudflare (Workers + Containers) | Pass | Pass | Pass | Pass | Pass | 5.0 | Low: D1 (SQLite) is a poor relational fit, so the DB goes elsewhere; EU pinning of containers unverified |
| Render | Pass | Pass | Pass | Partial | Partial | 4.0 | Low: object storage is early access; rollback not in CLI |
| Fly.io | Pass | Pass | Pass | Partial | Partial | 4.0 | Low: Warsaw region deprecated; Managed Postgres from $38/month |
| Vercel | Pass | Partial | Pass | Partial | Pass | 4.0 | Low: .NET only via Container runtime (**beta**); Postgres via Neon marketplace |
| Netlify | — | — | — | — | — | — | **Dropped**: cannot run .NET |

Status checked 2026-11-03 for every feature below.

- **Azure App Service.** The `az webapp` CLI covers deploy, log tail, config and slot swap. Docs are Markdown in `MicrosoftDocs/azure-docs` and `dotnet/AspNetCore.Docs`, and the Microsoft Learn MCP server is free with no sign-in (GA status not confirmed). Deploys run through `azure/webapps-deploy@v3` with OIDC. The Azure MCP Server is GA (1.0 in Oct 2025, 3.0 on 2026-10-29), but its App Service tools are thin: there's no log-reading tool, which is why MCP scores Partial. B1 Linux costs ~$13/month and S1 (the cheapest tier with deployment slots) ~$69/month. Auto swap is **not supported on Linux**, and `az webapp exec` is **preview**.
- **Azure Container Apps.** It has native revisions (rollback by traffic split), `az containerapp logs show --follow`, and a monthly free grant (180k vCPU-s, 2M requests). It needs an Azure Container Registry (~$5/month). Its GitHub Action generates a workflow only with a Dockerfile. Scale-to-zero cold start is 1–3 s by third-party estimates, and it stacks on the 10 s extraction budget. Building without a Dockerfile (`az containerapp up --source`) launched as **preview** in 2023 and the current docs carry no label.
- **Railway.** It has a good CLI (`railway up --ci` exits non-zero on failure), `llms.txt`, Postgres, and Buckets (**GA 2025-11-28**, Tigris sub-processor in EU West). Railpack's .NET detection needs the `.csproj` at the build root and is not on Railway's official language list, so a multi-stage Dockerfile is required. `railway.json`/`railway.toml` is **deprecated with a hard cutoff on 2026-12-01**. The MCP server is described as a work in progress.
- **Cloudflare.** It is excellent on every agent criterion: `wrangler deploy` / `rollback` / `tail`, `llms.txt`, and MCP. Containers have been **GA since 2026-04-13**. Its only native relational store is D1 (SQLite), so EF Core with SQL Server or Postgres needs an external database, which goes against the co-location answer. There's no documented EU region pinning for containers.
- **Render.** .NET is Docker-only. The CLI has been GA since 2024-12, but rollback goes through the Dashboard or API, not the CLI. Object Storage is **early access**, so photos need an external S3 store. The MCP server was announced as **early access** in 2025-06. A free instance spins down and takes ~1 minute to start, so a $7 instance plus $6 Postgres is the minimum.
- **Fly.io.** `fly launch` detects .NET and generates a Dockerfile. There's no native rollback (you redeploy the old image), and `fly mcp server` is **experimental**. Warsaw (`waw`) is **deprecated**, so `fra` or `ams` would be used. Managed Postgres starts at $38/month, which is the largest cost penalty under the cost answer.
- **Vercel.** The Container runtime is **beta** and is the only way to run .NET. Hobby is non-commercial only (acceptable for a personal app), and Pro is $20/user/month. Its MCP server is official.

### Shortlisted Platforms

#### 1. Azure App Service (Recommended)

It needs the fewest moving parts for this stack: no Dockerfile, no registry, no container start-up. The SPA ships inside the API's publish output (`wwwroot` + `MapFallbackToFile("index.html")`), so cookies stay on one origin exactly as AGENTS.md requires. Azure SQL (free offer, GA: 100k vCore-seconds and 32 GB per month for the life of the subscription) and Blob Storage (Hot LRS, under $1/month at this volume) sit in the same region and the same resource group. Poland Central is the closest region to the user. GitHub Actions with OIDC is a documented, first-party path that matches the planned "deploy on merge to master" flow.

#### 2. Azure Container Apps

It keeps every Azure advantage and adds the best rollback story on the list: revisions are retained and traffic can be pointed back at a previous revision with no slot tier. It loses on extra parts (ACR, Container Apps environment, Log Analytics workspace by default) and on scale-to-zero cold starts, which sit badly with the 10-second extraction requirement unless `minReplicas=1` (which removes most of the cost advantage). It's the natural next step if the app later needs containers.

#### 3. Railway

It's the best non-Azure option: cheap (~$5–10/month), Postgres and Buckets co-located, an Amsterdam region, `llms.txt`, and a CI-friendly CLI. The gaps are a hand-written Dockerfile (Railpack can't find the nested `.csproj` and can't build Angular and .NET together), a config-as-code format that is cut off on 2026-12-01, and no existing familiarity.

## Anti-Bias Cross-Check: Azure App Service

### Devil's Advocate — Weaknesses

1. **The runtime is at end of life on day one.** .NET 9 (STS) reaches end of support on 2026-11-10. App Service keeps running an expired stack (hidden in the portal, still settable through the CLI) but stops patching it. .NET 10 on App Service Linux was **preview** from 2025-08, and no Linux GA announcement was found on 2026-11-03. The first deploy either runs an unpatched runtime or depends on a stack whose status is unverified.
2. **B1 has no deployment slots, so there's no instant rollback.** Slots start at S1 (~$69/month). On B1, rolling back means redeploying a previous artifact, which takes minutes and depends on that artifact still existing.
3. **The Azure SQL free offer pauses when its allowance runs out.** By default the database pauses for the rest of the month once its 100k vCore-seconds are used, and a resume adds latency that can blow the 10 s extraction NFR.
4. **Data Protection keys are per-slot.** Keys live in `%HOME%/ASP.NET/DataProtection-Keys`. They survive restarts on one slot, but a later move to slots or containers would invalidate every sign-in cookie unless the keys are moved to Blob Storage.
5. **Agent operations are CLI-only in practice.** The Azure MCP Server has no App Service log tool, and the `az` CLI is not installed on the development machine yet (verified 2026-11-03).

### Pre-Mortem — How This Could Fail

The team deployed .NET 9 to App Service B1 the week support ended, reasoning that "it still runs". In January a CVE landed in ASP.NET Core 9 with no patched runtime. The rushed upgrade to .NET 10 hit Linux stack issues and a changed startup command, and with no staging slot every attempt went straight to production. Meanwhile the free Azure SQL database used up its vCore allowance mid-month and paused. The first receipt upload after each pause took 40 seconds and the client timed out, so the only user, the author, stopped trusting the extraction screen. Each fix redeployed over the last working build, and no one had kept the artifact of the last good run, so rollback meant guessing which commit was safe. Cookie keys had been left in the default location, so adding a staging slot later logged everyone out at each swap. No single failure was catastrophic. The real failure was mistaking "familiar platform" for "configured platform": the runtime lifecycle, database pausing and rollback were never planned.

### Unknown Unknowns

- **Publish-profile deploys fail by default.** New web apps have SCM basic auth turned off, so GitHub Actions must use OIDC federated credentials (`azure/login@v2`), not a publish profile.
- **Build automation guesses the project.** Zip deploy with Oryx build picks the first web project it finds. Build in CI and deploy already-published output (`az webapp deploy --type zip` of `dotnet publish` output).
- **TLS ends at Azure's front end.** Without `app.UseForwardedHeaders()` (with `X-Forwarded-Proto`), ASP.NET Core sees HTTP, so cookie `Secure` handling and HTTPS redirects misbehave. This matters for the cookie sign-in.
- **ARR affinity is on by default.** It is harmless on one instance but hides statelessness bugs, so disable it.
- **Quota is per subscription and region.** Trial and student subscriptions can have zero B1 quota in some regions, Poland Central included. Check before creating the plan, and fall back to West Europe or North Europe.

## Operational Story

- **Preview deploys**: None on B1, because slots require S1. For the MVP, PRs build and test in GitHub Actions without deploying. If previews become necessary, upgrade to S1 and add a `staging` slot (deploy there, then `az webapp deployment slot swap`), and move Data Protection keys to Blob Storage first.
- **Secrets**: App settings and connection strings live in App Service configuration (`az webapp config appsettings set`), encrypted at rest and readable only by subscription or resource-group RBAC holders. The AI provider key and the SQL connection string go there. GitHub holds only the OIDC identifiers (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`), not a password. Rotation: generate a new key at the provider, run `az webapp config appsettings set` (the app restarts automatically), then revoke the old key. Later you can add Key Vault references plus a managed identity to remove secrets from app settings.
- **Rollback**: Re-run the GitHub Actions deploy job of the last good `master` commit (`gh run rerun <run-id>`), or run `az webapp deploy -g rg-expify -n <app> --src-path <previous.zip> --type zip` with an artifact kept from CI. Expect about 2–5 minutes to revert. EF Core migrations do **not** roll back automatically: write migrations forward-compatible (additive first) and apply them as a separate, deliberate step.
- **Approval**: A human creates the Azure resources, does the OIDC/app-registration setup, changes tiers, rotates secrets, drops or restores databases, and deletes resources. The agent may run, unattended: builds, tests, `az webapp log tail`, read-only `az` queries (`az webapp show`, `az webapp config appsettings list --query [].name`), and triggering the CI deploy by merging to `master` once a human has approved the PR.
- **Logs**: Run `az webapp log config -g rg-expify -n <app> --docker-container-logging filesystem` once, then `az webapp log tail -g rg-expify -n <app>` for runtime logs and `az webapp log download` for history. Pipeline logs are in `gh run list --workflow <deploy>.yml` and `gh run view <run-id> --log-failed`.

## Risk Register

| Risk | Source | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| .NET 9 reaches end of support 2026-11-10; the deployed runtime stops getting patches | Research finding / Devil's advocate | H | H | Before the first deploy, run `az webapp list-runtimes --os linux` and check for `DOTNETCORE:10.0`. If it's there, upgrade to `net10.0` in a dedicated change and update `global.json`, the AGENTS.md hard rule and `tech-stack.md` together (re-run `/10x-tech-stack-selector` if needed). If it isn't, deploy `DOTNETCORE:9.0` set through the CLI and track the upgrade as the first post-deploy task. |
| .NET 10 on App Service Linux may still be preview or unstable | Unknown unknowns | M | M | Deploy a hello-world `net10.0` app to a throwaway B1 app before migrating; keep the .NET 9 build artifact as a fallback. |
| No deployment slots on B1, so rollback is a redeploy taking minutes | Devil's advocate | M | M | Keep each `dotnet publish` zip as a CI artifact (90-day retention) and document `gh run rerun` as the rollback. Upgrade to S1 only if previews are needed. |
| Azure SQL free offer pauses when the monthly allowance is used up, adding cold resume latency | Devil's advocate / Pre-mortem | M | H | Set the free-offer behaviour to "continue using database for additional charges" with an Azure budget alert (e.g. $5), or set the auto-pause delay to 1 hour minimum. Measure first-request latency after a pause. |
| Cookie keys lost or not shared across slots, logging users out | Devil's advocate / Pre-mortem | L (B1) / H (with slots) | M | Configure `AddDataProtection().PersistKeysToAzureBlobStorage(...)` before introducing any slot or container. |
| Publish-profile deploy fails because basic auth is disabled | Unknown unknowns | H | L | Use OIDC: an app registration with a federated credential for `repo:<owner>/Expify:ref:refs/heads/master` and the Website Contributor role on the web app only. |
| App sees HTTP behind the front end, breaking `Secure` cookies and redirects | Unknown unknowns | H | M | Add `ForwardedHeadersOptions { ForwardedHeaders = XForwardedFor \| XForwardedProto }` and `app.UseForwardedHeaders()` before auth middleware. |
| Oryx build picks the wrong project | Unknown unknowns | M | L | Build in GitHub Actions; deploy pre-built output with `SCM_DO_BUILD_DURING_DEPLOYMENT=false`. |
| B1 quota unavailable in Poland Central on the subscription | Unknown unknowns | L | L | Check with `az vm list-usage`/the portal Quotas blade, and fall back to `westeurope`. |
| Agent can't read live logs without the `az` CLI; Azure MCP has no App Service log tool | Devil's advocate / Research finding | H | L | Install the Azure CLI (`winget install -e --id Microsoft.AzureCLI`); log in with an account scoped to the `rg-expify` resource group. |
| Cost drift beyond ~$13/month (B1 + Blob + SQL overage) | Research finding | L | L | Create a resource-group budget with a $20 alert at setup. |

## Getting Started

These steps are checked against the repo as of 2026-11-03: API on `net9.0`, `global.json` 9.0.x, Angular 22 application builder (output in `dist/<project>/browser`). They're the input to the Plan Mode deploy, not a substitute for it.

1. **Install and sign in to the Azure CLI**, then check which .NET stacks App Service Linux offers today:
   ```powershell
   winget install -e --id Microsoft.AzureCLI
   az login
   az webapp list-runtimes --os linux | Select-String DOTNETCORE
   ```
   This decides `--runtime` below (`DOTNETCORE:10.0` after the upgrade, or `DOTNETCORE:9.0` with the end-of-support risk accepted).
2. **Create the resources** (human-run; a one-time step):
   ```powershell
   az group create -n rg-expify -l polandcentral
   az appservice plan create -g rg-expify -n asp-expify --is-linux --sku B1
   az webapp create -g rg-expify -p asp-expify -n expify-<unique> --runtime "DOTNETCORE:9.0"
   az webapp config set -g rg-expify -n expify-<unique> --always-on true --http20-enabled true
   az webapp update -g rg-expify -n expify-<unique> --client-affinity-enabled false --https-only true
   ```
   Then create the Azure SQL database with the free offer and a Storage account (Blob container `receipts`, private) in the same resource group.
3. **Make the API serve the SPA on one origin.** Add `app.UseForwardedHeaders()`, `app.UseDefaultFiles()`, `app.UseStaticFiles()` and `app.MapFallbackToFile("index.html")` to `Program.cs`, keeping every endpoint under `/api/...`. Build the frontend (`npm run build` in `src/Expify.Web`) and copy `dist/expify-web/browser/*` into the API's `wwwroot` before publishing. Check the exact `dist` folder name against `angular.json`.
4. **Publish and deploy once by hand** to prove the path works:
   ```powershell
   dotnet publish src/Expify.Api -c Release -o publish
   Compress-Archive -Path publish/* -DestinationPath app.zip -Force
   az webapp deploy -g rg-expify -n expify-<unique> --src-path app.zip --type zip
   az webapp log tail -g rg-expify -n expify-<unique>
   ```
5. **Wire GitHub Actions with OIDC.** Create an app registration with a federated credential for `master`, grant it Website Contributor on the web app, and store `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` as repo secrets. Then use `azure/login@v2` + `azure/webapps-deploy@v3` in a workflow that triggers on `master`. Writing the workflow itself is part of the deploy plan, not this research.

## Out of Scope

The following were not evaluated in this research:
- Docker image configuration
- CI/CD pipeline setup (beyond naming the actions and auth method)
- Production-scale architecture (multi-region, HA, DR)
- Choice of AI vision provider and its own region and latency
