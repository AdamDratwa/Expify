---
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
---

## Why this stack

A solo .NET developer building a single-user receipt manager with email and password sign-in and AI extraction of receipt fields. The recommended default for a web app in .NET is the ASP.NET Core webapi starter, which the registry marks as verified for bootstrapping and which passes all four agent-friendly gates (typed, convention-based, popular in training data, well documented). That covers the backend API, which targets .NET 9. The frontend is Angular 22 in `src/Expify.Web`, chosen after the starter because the developer wants Angular experience. It reaches the API through a dev proxy on `/api`, so sign-in can use same-origin cookies. Deployment defaults to Azure App Service, and CI runs on GitHub Actions with auto-deploy on merge to master.

## AI extraction provider

Receipt fields are read by **GPT-6.1 Sol through OpenRouter**, one API key and the OpenAI-compatible chat-completions API, with the OpenRouter slug `openai/gpt-6.1-sol`. Requests deny data collection and require providers to honor the JSON-schema response format. Expect about 15 s per receipt; the latency target is being relaxed to 20 s. The evidence, privacy terms and what S-02 inherits are in `context/changes/extraction-provider-spike/decision.md`.
