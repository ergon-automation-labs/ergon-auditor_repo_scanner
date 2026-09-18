SCRIPTS_DIRECTORY ?= $(abspath $(CURDIR)/../scripts)
# Toolchain locations are machine-specific, so they are resolved per machine by
# the versioned resolver in the shared scripts dir (scripts/bot-helpers/portable.mk).
SCRIPTS_DIRECTORY ?= $(abspath $(CURDIR)/../scripts)
PORTABLE_MK := $(SCRIPTS_DIRECTORY)/portable.mk
ifneq ($(wildcard $(PORTABLE_MK)),)
include $(PORTABLE_MK)
else ifeq ($(strip $(MIX)),)
$(error mix: no portable resolver at $(PORTABLE_MK) and no MIX set — run `make install-helpers` in the elixir_bots monorepo, or pass MIX=/path/to/mix)
else
$(warning no portable resolver at $(PORTABLE_MK) — using MIX=$(MIX) as-is; run `make install-helpers` for portable resolution)
endif

.PHONY: setup help deps test credo dialyzer coverage check format clean release publish-release setup-hooks setup-db reset-db logs push-and-publish

help:
	@echo "Repo Scanner Bot"
	@echo ""
	@echo "Setup commands:"
	@echo "  make setup           - Set up project (deps.get + install git hooks + setup database)"
	@echo "  make setup-hooks     - Install git hooks for pre-push validation"
	@echo "  make setup-db        - Create and migrate test database (required for testing)"
	@echo "  make reset-db        - Drop and recreate test database (useful for troubleshooting)"
	@echo ""
	@echo "Development commands:"
	@echo "  make test            - Run all tests"
	@echo "  make credo           - Run linter"
	@echo "  make dialyzer        - Run static analysis"
	@echo "  make coverage        - Run tests with coverage"
	@echo "  make check           - Run all checks (test, credo, dialyzer)"
	@echo "  make format          - Format Elixir code"
	@echo "  make clean           - Clean build artifacts"
	@echo ""
	@echo "Operations (deployed server logs):"
	@echo "  make logs            - Tail server log with grc (auto-detected by repo name; make -C .. install-grc)"
	@echo ""
	@echo "Release commands:"
	@echo "  make release         - Build OTP release locally"
	@echo "  make publish-release - Build, package, and publish to GitHub"
	@echo ""
	@echo "Normal workflow:"
	@echo "  git push             - Fast compile+test validation"
	@echo "  make push-and-publish - Push then publish release asset"
	@echo ""

setup: init deps setup-hooks setup-db
	@echo "✓ Setup complete!"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Configure .env with your database settings (if needed)"
	@echo "  2. Run: make test"
	@echo "  3. Start developing!"
	@echo ""

setup-hooks:
	@git config core.hooksPath git-hooks
	@echo "✓ Git hooks installed (core.hooksPath = git-hooks)"

setup-db:
	@echo "Setting up test database..."
	@MIX_ENV=test $(MIX) ecto.create || true
	@MIX_ENV=test $(MIX) ecto.migrate
	@echo "✓ Test database created and migrations applied"

reset-db:
	@echo "⚠️  Resetting test database (dropping and recreating)..."
	@MIX_ENV=test $(MIX) ecto.drop || true
	@MIX_ENV=test $(MIX) ecto.create
	@MIX_ENV=test $(MIX) ecto.migrate
	@echo "✓ Test database reset complete"

init:
	@if [ ! -d .git ]; then git init; echo "Git initialized."; else echo "Git already initialized."; fi

deps:
	$(MIX) deps.get

test:
	$(MIX) test

credo:
	$(MIX) credo

dialyzer: deps
	$(MIX) dialyzer

coverage:
	$(MIX) coveralls

check: test credo dialyzer
	@echo "All checks passed!"

format:
	$(MIX) format

clean:
	$(MIX) clean
	rm -rf _build cover

release: check
	@echo "==============================================="
	@echo "Building OTP release"
	@echo "==============================================="
	rm -rf _build/prod/rel/repo_scanner_bot
	MIX_ENV=prod $(MIX) release
	@echo ""
	@echo "✓ Release built successfully"
	@echo "Location: _build/prod/rel/repo_scanner_bot/"
	@echo ""

publish-release: release
	@if ! git rev-parse --git-dir > /dev/null 2>&1; then \
		echo "❌ Not a git repository"; \
		exit 1; \
	fi; \
	if ! git config --get remote.origin.url | grep -q "ergon-automation-labs"; then \
		echo "⚠️  Warning: Remote is not from ergon-automation-labs"; \
		echo "   Remote: $$(git config --get remote.origin.url)"; \
	fi
	@echo "==============================================="
	@echo "Publishing release to GitHub"
	@echo "==============================================="
	@echo ""
	@echo "Repo: $$(basename $$(pwd))"
	@echo "Branch: $$(git rev-parse --abbrev-ref HEAD)"
	@echo ""

	@set -e; \
	VERSION=$$(sed -n 's/^[[:space:]]*version:[[:space:]]*"\([^"]*\)".*/\1/p' mix.exs | head -n 1); \
	if [ -z "$$VERSION" ]; then \
		echo "Failed to resolve version from mix.exs"; \
		exit 1; \
	fi; \
	TARBALL="repo_scanner_bot-$$VERSION.tar.gz"; \
	echo "Version: $$VERSION"; \
	echo "Creating release tarball..."; \
	tar -czf "$$TARBALL" -C _build/prod/rel repo_scanner_bot/; \
	echo "✓ Tarball created: $$TARBALL"; \
	echo ""; \
	echo "Creating GitHub release v$$VERSION..."; \
	if gh release view "v$$VERSION" >/dev/null 2>&1; then \
		gh release upload "v$$VERSION" "$$TARBALL" --clobber; \
	else \
		gh release create "v$$VERSION" "$$TARBALL" \
			--title "Release v$$VERSION" \
			--notes "Repo Scanner Bot Elixir release v$$VERSION. Download and deploy with Jenkins." \
			--draft=false; \
	fi; \
	echo "✓ Release published to GitHub"; \
	echo ""; \
	echo "Writing release marker..."; \
	echo "$$VERSION $$(date -u +%s)" > .release-published; \
	echo "✓ Release marker written"; \
	echo ""; \
	echo "Publishing deploy.release.requested to NATS..."; \
	BOT_SHORT=$$(echo "repo_scanner_bot" | sed 's/_bot$$//'); \
	REPO_SLUG=$$(git config --get remote.origin.url | sed -E 's#.*[:/]([^/]+/[^/]+)\.git#\1#'); \
	MONOREPO_ROOT=$$($(call _FIND_MONOREPO_ROOT)); \
	NATS_PUBLISH_SCRIPT="$$MONOREPO_ROOT/bot_army_infra/salt/common/files/nats_publish.sh"; \
	if [ -n "$$MONOREPO_ROOT" ] && [ -f "$$NATS_PUBLISH_SCRIPT" ]; then \
		PAYLOAD=$$(printf '{"bot":"%s","repo":"%s","tag":"v%s","version":"%s"}' "$$BOT_SHORT" "$$REPO_SLUG" "$$VERSION" "$$VERSION"); \
		bash "$$NATS_PUBLISH_SCRIPT" deploy.release.requested "$$PAYLOAD" || echo "⚠️  NATS publish failed (non-fatal — deploy via make deploy-bot or Jenkins instead)"; \
	else \
		echo "⚠️  nats_publish.sh not found (monorepo root: $${MONOREPO_ROOT:-not found}) — skipping deploy.release.requested"; \
	fi; \
	echo ""; \
	echo "Next steps:"; \
	echo "1. If this bot's ci_engine is 'nats' (pillar/common.sls in bot_army_infra), deploy_pipeline_bot deploys it automatically."; \
	echo "2. Otherwise: make deploy-bot, or wait for Jenkins polling"; \
	echo "3. Check status: make jenkins-logs (Jenkins) or watch ops.deploy.* on NATS (deploy_pipeline_bot path)"

push-and-publish:
	@git push && $(MAKE) publish-release

logs:
	@$(SCRIPTS_DIRECTORY)/tail_bot_log.sh

# Deployment targets that delegate to monorepo
.PHONY: deploy-bot verify-bot verify-bot-nats

_FIND_MONOREPO_ROOT = \
	if [ -n "$(MONOREPO_ROOT)" ]; then \
		echo "$(MONOREPO_ROOT)"; \
		exit 0; \
	fi; \
	if [ -d "../../../elixir_bots" ] && [ -f "../../../elixir_bots/Makefile" ]; then \
		if grep -q "verify-bot-nats:" "../../../elixir_bots/Makefile"; then \
			echo "$$(cd ../../../elixir_bots && pwd)"; \
			exit 0; \
		fi; \
	fi; \
	CURRENT_DIR=$$(pwd); \
	while [ "$$CURRENT_DIR" != "/" ]; do \
		if [ -f "$$CURRENT_DIR/Makefile" ] && grep -q "verify-bot-nats:" "$$CURRENT_DIR/Makefile"; then \
			if [ -d "$$CURRENT_DIR/bots" ] || [ -d "$$CURRENT_DIR/bot_army_infra" ]; then \
				echo "$$CURRENT_DIR"; \
				exit 0; \
			fi; \
		fi; \
		CURRENT_DIR=$$(dirname "$$CURRENT_DIR"); \
	done; \
	echo ""; \
	exit 1

deploy-bot:
	@MONOREPO_ROOT=$$($(call _FIND_MONOREPO_ROOT)) || { \
		echo "❌ Could not find monorepo root"; \
		echo "   Expected to find Makefile with 'deploy-bot' target"; \
		echo "   Current directory: $$(pwd)"; \
		exit 1; \
	}; \
	DIR_NAME=$$(basename $$(pwd)); \
	echo "Deploying from: $$(pwd)"; \
	echo "Directory: $$DIR_NAME"; \
	echo "Monorepo root: $$MONOREPO_ROOT"; \
	echo ""; \
	$(MAKE) -C "$$MONOREPO_ROOT" deploy-bot BOT=$$DIR_NAME

verify-bot:
	@MONOREPO_ROOT=$$($(call _FIND_MONOREPO_ROOT)) || { \
		echo "❌ Could not find monorepo root"; \
		exit 1; \
	}; \
	BOT_NAME=$$(basename $$(pwd) | sed 's/bot_army_//'); \
	$(MAKE) -C "$$MONOREPO_ROOT" verify-bot BOT=$$BOT_NAME

verify-bot-nats:
	@MONOREPO_ROOT=$$($(call _FIND_MONOREPO_ROOT)) || { \
		echo "❌ Could not find monorepo root"; \
		exit 1; \
	}; \
	BOT_NAME=$$(basename $$(pwd) | sed 's/bot_army_//'); \
	$(MAKE) -C "$$MONOREPO_ROOT" verify-bot-nats BOT=$$BOT_NAME
