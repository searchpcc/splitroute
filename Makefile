.PHONY: install uninstall status logs version help

SHELL := /bin/bash

help: ## Show available commands
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-12s %s\n", $$1, $$2}'

install: ## Install splitroute
	@bash splitroute-setup.sh

uninstall: ## Uninstall completely
	@if command -v splitroute &>/dev/null; then \
		splitroute uninstall; \
	else \
		echo "splitroute is not installed"; \
	fi

status: ## Show service status, config, and routes
	@splitroute status 2>/dev/null || echo "splitroute is not installed. Run: make install"

logs: ## Show recent logs
	@splitroute logs 2>/dev/null || echo "splitroute is not installed. Run: make install"

version: ## Show version
	@splitroute version 2>/dev/null || cat VERSION
