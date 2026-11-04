# Repository Guidelines

Expify is a personal spending tracker built around receipts. It has an ASP.NET Core Web API on .NET 9 (`src/Expify.Api`) and an Angular 22 frontend (`src/Expify.Web`). Product scope is in @context/foundation/prd.md. The repo is still the scaffold, so no MVP feature exists yet.

## Hard rules

- Never write to `context/archive/`. It is read-only. Put in-flight work in `context/changes/<change-id>/`.
- Target `net9.0` only. `global.json` pins SDK 9.0.x. An earlier scaffold silently used the machine's SDK 10 and had to be redone.
- Map every endpoint the frontend calls under `/api/...`. The dev proxy (@src/Expify.Web/proxy.conf.json) forwards only `/api` to `http://localhost:5066` and does not rewrite the path. Sign-in relies on that single origin for cookies.
- When working on the frontend, run the API with the `http` launch profile. Under `https`, `UseHttpsRedirection` redirects proxied calls to port 7091 and breaks the proxy.
- Never commit `src/Expify.Api/wwwroot/`. CI generates it from the Angular build, and it is in `.gitignore`.
- Every push to `master` deploys to production (`https://expify-adr.azurewebsites.net`). Don't push. The user pushes, and does every GitHub web UI action (secrets, re-runs, rollback) by hand; `gh` is not available.
- Don't add an `environment:` key to the deploy job. It changes the OIDC subject and breaks `azure/login`. The federated credential subject uses numeric IDs: `repo:AdamDratwa@22412061/Expify@1444649362:ref:refs/heads/master`.

## Project Structure

- `src/Expify.Api/`: a minimal API, currently all in `Program.cs`. It is the only project in `Expify.sln`.
- `src/Expify.Web/`: a standalone Angular app. Providers are in `src/app/app.config.ts` and routes in `src/app/app.routes.ts`.
- `context/` holds planning docs (`foundation/`) and change records (`changes/`).

## Build and Development Commands

- `dotnet build Expify.sln` builds the API only. The Angular app is not in the solution.
- How to start API and frontend app is described in @README.md
- `npm run build` fails if the initial bundle is over 1 MB or any component style is over 8 kB.
- Audit commands are in @README.md.

## Coding Style

- No linter is configured. The frontend uses Prettier (@src/Expify.Web/.prettierrc), which has no npm script. Run `npx prettier --check .` in `src/Expify.Web`.

## Testing Guidelines

- To run one spec: `npx ng test --watch=false --include src/app/app.spec.ts`.
- `src/app/app.spec.ts` checks for the placeholder "Hello, expify-web" heading. Update it when you replace `app.html`.
- The API has no test project yet.

## Commit and Pull Request Guidelines

- The history is a single `initial commit`, so there is no commit convention yet.
- The deploy workflow in .github/workflows/ must trigger on master. Don't rename the branch or target master unless the README and tech-stack notes are updated in the same change
