# Expify

Expify is a personal spending tracker built around receipts. You photograph a receipt, AI reads the store, date, items, categories and total, you check and correct the result, and the saved receipt shows up in a monthly breakdown of spending by category. You can set a monthly limit per category, and the app warns you when a category goes over it.

> **Status:** early development. The repository holds the scaffolded API and frontend, deployed at <https://expify-adr.azurewebsites.net>. The features below are planned for the MVP and are not built yet.

## MVP features

- Sign in with email and password; each account sees only its own receipts and photos.
- Upload a receipt photo and get the extracted fields within about 10 seconds.
- Review and correct every extracted field before saving. Nothing is saved without your review.
- View the month's spending as a chart, grouped by category, with a total.
- Set a monthly limit per category and see a warning next to any category that exceeds it.
- Works in a mobile phone browser.

Out of scope for the MVP: natural-language questions about spending, email or push alerts, and month-to-month progress comparison. See [context/foundation/prd.md](context/foundation/prd.md) for the full requirements.

## Tech stack

| Part | Technology | Location |
| --- | --- | --- |
| Backend API | ASP.NET Core Web API, .NET 9 | [src/Expify.Api](src/Expify.Api) |
| Frontend | Angular 22, SCSS, Vitest | [src/Expify.Web](src/Expify.Web) |
| Hosting | Azure App Service (Linux B1, Poland Central), app `expify-adr` | <https://expify-adr.azurewebsites.net> |
| CI/CD | GitHub Actions, deploy on push to `master` | [.github/workflows/deploy.yml](.github/workflows/deploy.yml) |

The reasoning behind these choices is in [context/foundation/tech-stack.md](context/foundation/tech-stack.md).

## Repository layout

```
Expify.sln              Solution file (API project)
global.json             Pins the .NET SDK to 9.0.x
src/
  Expify.Api/           ASP.NET Core Web API
  Expify.Web/           Angular frontend
context/
  foundation/           Product and stack decisions (PRD, tech stack, shaping notes)
  changes/              Records of in-progress changes
  archive/              Completed changes (read-only)
```

## Getting started

### Prerequisites

- [.NET SDK 9.0](https://dotnet.microsoft.com/download/dotnet/9.0) (pinned in [global.json](global.json); later 9.0 feature bands also work)
- [Node.js](https://nodejs.org/) with npm 11 (the frontend declares `npm@11.20.0`)

### Run the API

```bash
dotnet run --project src/Expify.Api
```

The API listens on `http://localhost:5066` (the `http` launch profile). Use `--launch-profile https` to also serve `https://localhost:7091`. In Development, the OpenAPI document is available at `/openapi/v1.json`.

### Run the frontend

```bash
cd src/Expify.Web
npm install
npm start
```

Open `http://localhost:4200`. The dev server forwards requests under `/api` to the API on `http://localhost:5066` (see [proxy.conf.json](src/Expify.Web/proxy.conf.json)), so the browser talks to one origin and sign-in can use same-origin cookies. Start the API first.

## Building and testing

| Task | Command |
| --- | --- |
| Build the API | `dotnet build Expify.sln` |
| Build the frontend | `npm run build` (in `src/Expify.Web`; output in `dist/`) |
| Frontend unit tests | `npm test` (in `src/Expify.Web`) |
| Check API packages for vulnerabilities | `dotnet list Expify.sln package --vulnerable --include-transitive` |
| Check frontend packages for vulnerabilities | `npm audit` (in `src/Expify.Web`) |

The API has no test project yet.

## Deploy

Every push to `master` runs [deploy.yml](.github/workflows/deploy.yml):

1. **build:** frontend tests and build, copy the SPA into `src/Expify.Api/wwwroot/`, `dotnet publish`, and upload the `publish/` folder as the artifact `app-<sha>` (kept 90 days).
2. **deploy:** sign in to Azure with OIDC (no stored password), deploy the artifact to `expify-adr`, then smoke-test `/api/health`.

Pull requests to `master` run only the build job. The workflow can also be started by hand from the Actions tab.

GitHub settings the workflow needs (Settings → Secrets and variables → Actions):

- Secrets: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
- Variable: `AZURE_WEBAPP_NAME` = `expify-adr`

**Rollback:** in the Actions tab, open the last good run and choose "Re-run all jobs". If that run's code no longer builds, download its `app-<sha>` artifact, zip the contents, and run:

```powershell
az webapp deploy -g rg-expify -n expify-adr --src-path app.zip --type zip
```

**Logs:** `az webapp log tail -g rg-expify -n expify-adr`

Full deploy history and setup steps are in [context/deployment/deploy-plan.md](context/deployment/deploy-plan.md).

## Project documents

- [Product requirements](context/foundation/prd.md)
- [Tech stack decision](context/foundation/tech-stack.md)
- [Infrastructure decision](context/foundation/infrastructure.md)
- [Deploy plan and log](context/deployment/deploy-plan.md)
- [Shaping notes](context/foundation/shape-notes.md)
- [Bootstrap verification log](context/changes/bootstrap-verification/verification.md)
