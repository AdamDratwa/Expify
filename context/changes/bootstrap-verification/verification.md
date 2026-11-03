---
bootstrapped_at: 2026-11-03T14:35:25 (local time); re-scaffolded on .NET 9 the same day
starter_id: dotnet
starter_name: .NET (ASP.NET Core webapi)
project_name: expify
language_family: dotnet
package_manager: dotnet
cwd_strategy: subdir-then-move
bootstrapper_confidence: verified
phase_3_status: ok
audit_command: dotnet list package --vulnerable --include-transitive
---

## Hand-off

Verbatim copy of `context/foundation/tech-stack.md` frontmatter:

```yaml
starter_id: dotnet
package_manager: dotnet
project_name: expify
hints:
  language_family: dotnet
  team_size: solo
  deployment_target: azure-app-service
  ci_provider: github-actions
  ci_default_flow: auto-deploy-on-merge
  bootstrapper_confidence: verified
  path_taken: standard
  quality_override: false
  self_check_answers: null
  has_auth: true
  has_payments: false
  has_realtime: false
  has_ai: true
  has_background_jobs: false
```

## Why this stack

A solo .NET developer building a single-user receipt manager with email and password sign-in and AI extraction of receipt fields. The recommended default for a web app in .NET is the ASP.NET Core webapi starter, which the registry marks as verified for bootstrapping and which passes all four agent-friendly gates (typed, convention-based, popular in training data, well documented). That covers the backend API. The frontend the PRD requires is not part of this starter and needs its own decision. Deployment defaults to Azure App Service, and CI runs on GitHub Actions with auto-deploy on merge to main.

## Pre-scaffold verification

| Signal             | Value                                  | Severity | Notes                                                        |
| ------------------ | -------------------------------------- | -------- | ------------------------------------------------------------ |
| npm package        | not run                                | n/a      | Non-JS starter (dotnet)                                      |
| GitHub repo        | not run                                | n/a      | docs_url is learn.microsoft.com, not a GitHub repository     |

No recency signal was available for this starter. The check was informational only and did not affect the scaffold.

## Scaffold log

**Current scaffold (manual re-scaffold at the user's request)**:

```
global.json                     # pins SDK 9.0.319, rollForward latestFeature
dotnet new sln -n Expify
dotnet new webapi -n Expify.Api -o src/Expify.Api -f net9.0
dotnet sln Expify.sln add src/Expify.Api/Expify.Api.csproj
dotnet new gitignore
```

**Strategy**: manual (run directly in the repo root, not through the bootstrapper's temp-directory flow)
**Exit code**: 0 for every command; `dotnet build Expify.sln` succeeds with 0 errors
**Layout**: `Expify.sln` at the root, API project at `src/Expify.Api/` (target `net9.0`)
**.gitignore handling**: created from the `dotnet new gitignore` template (the repo had none)
**`context/`**: not touched

**Superseded first run**: the bootstrapper first ran `dotnet new webapi -n .bootstrap-scaffold --no-restore` on SDK 10.0.103 (exit 0). The substituted `{name}` leaked into the file names (`.bootstrap-scaffold.csproj`), no solution file was created, and the target was `net10.0`. Those files were deleted and replaced by the re-scaffold above.

## Post-scaffold audit

**Tool**: `dotnet list Expify.sln package --vulnerable --include-transitive`
**Summary**: 0 CRITICAL, 0 HIGH, 0 MODERATE, 0 LOW
**Direct vs transitive**: no findings in either

The .NET 9 template references `Microsoft.AspNetCore.OpenApi` 9.0.21, and no vulnerable packages were reported. The HIGH transitive finding from the superseded .NET 10 run (`Microsoft.OpenApi` 2.0.0, GHSA-v5pm-xwqc-g5wc) does not apply to this scaffold.

## Hints recorded but not acted on

| Hint                    | Value                    |
| ----------------------- | ------------------------ |
| bootstrapper_confidence | verified                 |
| quality_override        | false                    |
| path_taken              | standard                 |
| self_check_answers      | null                     |
| team_size               | solo                     |
| deployment_target       | azure-app-service        |
| ci_provider             | github-actions           |
| ci_default_flow         | auto-deploy-on-merge     |
| has_auth                | true                     |
| has_payments            | false                    |
| has_realtime            | false                    |
| has_ai                  | true                     |
| has_background_jobs     | false                    |

Bootstrapper did not act on these. Deployment, CI/CD, and feature flags are recorded for the next steps; no CI workflow, Azure config, or agent instruction file was generated.

## Next steps

Next: a future skill will set up agent context (CLAUDE.md, AGENTS.md). For now, your project is scaffolded and verified.

Useful manual steps in the meantime:
- Frontend added separately: Angular 22.2.5 in `src/Expify.Web` (`npx @angular/cli@22.2.5 new expify-web --directory src/Expify.Web --defaults --style scss --ssr false --skip-git`). Build passes, 2 of 2 tests pass, npm audit reports 0 vulnerabilities. The dev server proxies `/api` to the API at `http://localhost:5066`.
