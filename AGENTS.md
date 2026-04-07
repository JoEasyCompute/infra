# Repository Guidelines

## Project Structure & Module Organization
`services/` holds application services; today the only runnable service is `services/fleet-catalog/`, with runtime code in `src/`, tests in `test/`, and MAAS fixtures in `test/fixtures/`. `db/` contains ordered SQL migrations and deterministic seed data. `docs/` stores architecture and local-development notes. `packages/domain/` is reserved for shared contracts and enums, and `infra/` is for future Terraform, image, and bootstrap assets.

## Build, Test, and Development Commands
- `cp .env.example .env && docker compose up -d postgres` — start the local PostgreSQL dependency from the repo root.
- `docker exec -i ezc-postgres psql -U postgres -d ezc_platform < db/seeds/0001_local_dev_seed.sql` — load the sample inventory dataset.
- `cd services/fleet-catalog && npm install` — install the current service dependencies.
- `cd services/fleet-catalog && npm start` — run the API with the shared repo-root `.env`.
- `cd services/fleet-catalog && npm run dev` — start the same service with file watching.
- `cd services/fleet-catalog && npm test` — run the Node test suite.
- `cd services/fleet-catalog && npm run sync:maas` — execute the manual MAAS sync after creating `config/maas-placement.json`.

## Coding Style & Naming Conventions
Match the existing Node.js style in `services/fleet-catalog/src`: ES modules, 2-space indentation, double quotes, and semicolons. Prefer small boundary-focused files such as `maas-client.js`, `repository.js`, and `placement.js`. Use kebab-case for directories, lowerCamelCase for functions, and descriptive exported names.

## Testing Guidelines
Tests use the built-in `node:test` runner with `assert/strict`. Add new tests beside the module they cover using the `*.test.js` suffix. Favor fixture-driven tests for MAAS payload shaping and keep database-facing behavior covered by request validation or repository-level assertions before changing sync logic.

## Commit & Pull Request Guidelines
Recent history uses short imperative subjects (`Add MAAS client and manual sync runner`). Keep that style for the first line, then follow the repo's Lore protocol with trailers such as `Constraint:`, `Rejected:`, `Confidence:`, and `Tested:`. PRs should link the issue, summarize schema/API changes, list verification commands, and include sample payloads or screenshots when behavior changes are externally visible.

## Security & Configuration Tips
Do not commit `.env`, MAAS API keys, or generated placement files. Start from `.env.example` and `services/fleet-catalog/config/maas-placement.example.json`. Keep local OMX state in `.omx/`, which is intentionally ignored.
