# Getting Started with bot_army_auditor_repo_scanner

This guide walks you through setting up Repo Scanner Bot for local development.

## Prerequisites

- **Elixir 1.14+** - Install via [elixir-lang.org](https://elixir-lang.org)
- **Erlang/OTP 25+** - Installed with Elixir
- **PostgreSQL** - For local database (optional for development)
- **Git** - For version control
- **GitHub CLI** (`gh`) - For releasing to GitHub

## Quick Start

### 1. Install Dependencies

```bash
make setup
```

This will:
- Initialize git if needed
- Run `mix deps.get`
- Install git hooks for pre-push validation

### 2. Set Up Environment Variables

Create a `.env` file from the template for local development and testing:

```bash
cp .env.example .env
```

Edit `.env` to match your local setup:

```bash
DATABASE_HOST=localhost          # Should match your local/Kubernetes setup
DATABASE_PORT=30003              # Kubernetes NodePort for postgres-vector
DATABASE_USER=postgres
DATABASE_PASSWORD=postgres
DATABASE_NAME=bot_army_auditor_repo_scanner_dev
```

**Important:** `.env` is gitignored and should never be committed. Use `.env.example` to document what variables are needed.

### 3. Set Up Test Database

The `make setup` target automatically sets up the test database with:
```bash
make setup-db
```

This creates the test database and runs migrations, allowing you to run tests immediately.

If you need to reset the database during development:
```bash
make reset-db  # Drops and recreates test database
```

### 4. Verify Setup

```bash
mix compile
mix test
```

Tests require the database to be running. If tests fail with database connection errors:
1. Verify your `.env` file matches your database setup
2. Ensure postgres-vector is running and accessible
3. Run `make reset-db` to recreate the test database

## Skill Development

Repo Scanner Bot uses the **BotArmy.GenBot** harness to run skills. Skills are discrete, reusable units of work triggered via NATS messages.

### Creating Your First Skill

1. **Start with the template** — `lib/bot_army_auditor_repo_scanner/skills/example.ex` is a fully documented template
2. **Copy and rename** it for your skill:
   ```bash
   cp lib/bot_army_auditor_repo_scanner/skills/example.ex lib/bot_army_auditor_repo_scanner/skills/my_skill.ex
   ```
3. **Implement the callbacks**:
   - `name/0` — Unique atom identifier (e.g., `:classify`, `:extract_entities`)
   - `description/0` — Human-readable description
   - `nats_triggers/0` — NATS subjects that invoke this skill
   - `llm_hint/0` — Hint for LLM routing (`:fast`, `:quality`, `:research`, `:none`)
   - `execute/2` — Main skill logic (receives input map and context)
   - `validate/1` — Optional input validation (defaults to accepting all)

### Example: A Classification Skill

```elixir
defmodule BotArmyAuditorRepoScanner.Skills.Classify do
  use BotArmy.Skill

  def name, do: :classify
  def description, do: "Classifies text into categories"
  def nats_triggers, do: ["bot.bot_army_auditor_repo_scanner.command.classify"]
  def llm_hint, do: :fast

  def execute(%{"text" => text}, ctx) do
    with {:ok, classification} <- ctx.llm.request("Classify: " <> text, hint: llm_hint()) do
      {:ok, %{classification: classification}}
    end
  end

  def validate(%{"text" => t}) when is_binary(t) and byte_size(t) > 0, do: :ok
  def validate(_), do: {:error, "text field required"}
end
```

### Registering Skills with GenBot

Once you've created skills, register them in your bot via the GenBot macro:

```elixir
# In lib/bot_army_auditor_repo_scanner/application.ex or similar

defmodule BotArmyAuditorRepoScanner.MyBot do
  use BotArmy.GenBot,
    skills: [
      BotArmyAuditorRepoScanner.Skills.Classify,
      BotArmyAuditorRepoScanner.Skills.ExtractEntities
    ],
    bot_id: :my_bot
end
```

GenBot will:
- Subscribe to all skill trigger subjects
- Route NATS messages to matching skills
- Inject context (personality, current context, LLM proxy)
- Run skills asynchronously
- Publish success/error events

### Skill Context

Every skill receives a context map:
```elixir
%{
  bot_id: :my_bot,                    # Bot identifier
  personality: %{...},                # Personality config
  context: %{...},                    # Current context from Context Broker
  llm: BotArmy.LLMProxy               # For calling LLM via NATS
}
```

### Using the LLM Proxy

Skills can call the LLM bot without knowing NATS details:

```elixir
{:ok, result} = ctx.llm.request(
  "Analyze this text: " <> text,
  hint: :fast,           # :fast, :quality, :research, or :none
  timeout: 15_000        # milliseconds
)
```

### Knowledge Graph Integration

If graph support is enabled, skills can extract entities and populate a knowledge graph:

```elixir
BotArmy.Graph.upsert_nodes([
  %{id: "alice", type: "person", name: "Alice", properties: %{email: "alice@example.com"}}
])

BotArmy.Graph.upsert_edges([
  %{from_id: "alice", to_id: "acme", type: "WORKS_AT", properties: %{since: 2024}}
])
```

See `bot_army_core` CLAUDE.md for more details.

## Development Workflow

### Code Changes

```bash
# Make your changes
edit lib/bot_army_auditor_repo_scanner/skills/my_skill.ex

# Format code
make format

# Run linter
make credo

# Run tests
make test
```

### Pushing to GitHub

```bash
git add .
git commit -m "Description of changes"
git push
```

When you push to `main`:
1. Pre-push hook runs `mix compile` and `mix credo`
2. Builds OTP release with `mix release`
3. Creates tarball
4. Publishes release to GitHub
5. Push completes

Jenkins automatically detects the new release and deploys it.

### Manual Release (if needed)

```bash
make release          # Build release locally
make publish-release  # Package and publish to GitHub
```

## Key Commands

```bash
make help             # Show all available commands
make setup            # Install dependencies, git hooks, and set up database
make setup-db         # Create and migrate test database (required for testing)
make reset-db         # Drop and recreate test database (useful for troubleshooting)
make test             # Run tests
make credo            # Run linter
make check            # Run all checks (test, credo, dialyzer)
make format           # Format Elixir code
make clean            # Remove build artifacts
```

## Release Configuration

The OTP release is configured in `mix.exs`:

```elixir
releases: [
  repo_scanner_bot: [
    applications: [bot_army_auditor_repo_scanner: :permanent]
  ]
]
```

This creates a release named `repo_scanner_bot` that is deployed to `/opt/ergon/releases/repo_scanner_bot/` on the server.

## Configuration

### Development Environment

Create a `.env` file in the project root for local development:

```bash
DATABASE_HOST=localhost
DATABASE_PORT=5432
DATABASE_USER=postgres
DATABASE_PASSWORD=postgres
DATABASE_NAME=bot_army_auditor_repo_scanner_dev
```

### Runtime Configuration

In production, configuration comes from Salt pillar via environment variables. See `pillar/common.sls` in `bot_army_infra` for details.

## Dependencies

Key dependencies:
- `bot_army_core` - Core library and NATS decoder
- `bot_army_runtime` - Persistence and messaging foundation
- `nats` - NATS client for message publishing/subscribing
- `jason` - JSON encoding/decoding
- `logger_json` - Structured JSON logging

Development dependencies:
- `credo` - Code linting
- `dialyxir` - Static type checking
- `excoveralls` - Code coverage

## Deployment

Deployment is automated via Jenkins. After you push to `main`:

1. Jenkins detects the new release on GitHub
2. Downloads the pre-built tarball
3. Extracts and deploys to `/opt/ergon/releases/repo_scanner_bot/`
4. Restarts the service

No manual deployment steps needed.

## Troubleshooting

### Build Fails: "Release directory not found"

Make sure the release name in `mix.exs` is correct:
```elixir
releases: [
  repo_scanner_bot: [
    applications: [bot_army_auditor_repo_scanner: :permanent]
  ]
]
```

### Database Connection Issues

Check `.env` file and `config/dev.exs`. Environment variables must match your local setup.

To reset the test database and fix migration issues:
```bash
make reset-db
make test
```

This drops the old database, creates a fresh one, runs all migrations, and ensures tests can run.

### Pre-push Hook Fails

The hook validates compilation and builds the release. If it fails:

1. Run `mix deps.get` to ensure dependencies are up to date
2. Run `mix compile` to check for compilation errors
3. Run `mix credo --strict` to check for linting issues
4. Fix errors and try pushing again

### GitHub Release Already Exists

The pre-push hook will warn if a release already exists but will continue with the push. You can safely retry or manually create a new release with a different version.

## Related Documentation

- `../../README.md` - Project overview
- `bot_army_repo_structure_1.md` in `bot_army_schemas` - Full polyrepo context
- `bot_army_infra` - Infrastructure and deployment configuration

## Questions?

Check the Makefile for all available commands or review the `CLAUDE.md` file for development guidelines.
