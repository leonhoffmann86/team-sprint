# Sprint plugin — project commands. Run `make` (or `make help`) for the list.
# This repo has no build/test toolchain; these targets just wrap the setup + doc steps.
.DEFAULT_GOAL := help

.PHONY: help setup docs check

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-7s\033[0m %s\n", $$1, $$2}'

setup: ## One-time per clone: activate the pre-push doc hook + make scripts executable
	chmod +x .githooks/* scripts/*.sh
	git config core.hooksPath .githooks
	@command -v claude >/dev/null 2>&1 || echo "⚠️  claude CLI not on PATH — docs-refresh will no-op until it is."
	@echo "✓ Setup done. pre-push doc-refresh active. Next: 'make docs' to regenerate, or just commit & push."

docs: ## Regenerate CLAUDE.md / ARCHITECTURE.md / README.md from sources (headless claude)
	scripts/docs-refresh.sh

check: ## Syntax-check every shell script (+ shellcheck if installed)
	@for f in .githooks/* scripts/*.sh templates/githooks/post-commit templates/scripts/*.sh; do \
	  bash -n "$$f" && echo "ok  $$f" || exit 1; \
	done
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck --severity=warning .githooks/* scripts/*.sh templates/githooks/post-commit templates/scripts/*.sh && echo "shellcheck: clean"; \
	else echo "(shellcheck not installed — skipped)"; fi

sync-agents: ## Sync agents/ → templates/.claude/agents/ (keep them identical)
	cp agents/*.md templates/.claude/agents/
	@echo "✓ agents/ synced to templates/.claude/agents/"
