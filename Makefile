SHELL := /bin/bash

PROJECT_NAME ?= devops-sandbox

.PHONY: up down create destroy logs health simulate clean ensure-dirs

up: ensure-dirs
	docker compose up -d
	bash ./platform/start_workers.sh

down:
	bash ./platform/stop_workers.sh
	@for state in envs/*.json; do \
		[ -f "$$state" ] || continue; \
		env_id="$${state##*/}"; \
		env_id="$${env_id%.json}"; \
		bash ./platform/destroy_env.sh "$$env_id"; \
	done
	docker compose down --remove-orphans

create:
	@name="$${ENV_NAME:-}"; \
	ttl="$${TTL:-}"; \
	if [ -z "$$name" ]; then \
		read -r -p "Environment name: " name; \
	fi; \
	if [ -z "$$ttl" ]; then \
		read -r -p "TTL in minutes [30]: " ttl; \
	fi; \
	ttl="$${ttl:-30}"; \
	bash ./platform/create_env.sh "$$name" "$$ttl"

destroy:
	@if [ -z "${ENV}" ]; then \
		printf "Usage: make destroy ENV=<env-id>\n" >&2; \
		exit 1; \
	fi
	bash ./platform/destroy_env.sh "${ENV}"

logs:
	@if [ -z "${ENV}" ]; then \
		printf "Usage: make logs ENV=<env-id>\n" >&2; \
		exit 1; \
	fi
	@state_file="envs/${ENV}.json"; \
	archive_file="logs/archived/${ENV}/app.log"; \
	if [ -f "$$state_file" ]; then \
		python3 ./platform/loki_logs.py tail --env "${ENV}" --limit 100; \
	elif [ -f "$$archive_file" ]; then \
		tail -n 100 "$$archive_file"; \
	else \
		printf "No logs found for %s\n" "${ENV}" >&2; \
		exit 1; \
	fi

health:
	@python3 -c "import json; from datetime import datetime, timezone; from pathlib import Path; now = datetime.now(timezone.utc); [print(f\"{data['id']}: status={data.get('status')} ttl_remaining_seconds={max(int(data.get('ttl_minutes', 0)) * 60 - int((now - datetime.fromisoformat(data['created_at'].replace('Z', '+00:00'))).total_seconds()), 0)}\") for state_file in sorted(Path('envs').glob('*.json')) for data in [json.loads(state_file.read_text(encoding='utf-8'))]]"

simulate:
	@if [ -z "${ENV}" ] || [ -z "${MODE}" ]; then \
		printf "Usage: make simulate ENV=<env-id> MODE=<mode>\n" >&2; \
		exit 1; \
	fi
	bash ./platform/simulate_outage.sh --env "${ENV}" --mode "${MODE}"

clean: down
	docker compose down --remove-orphans --volumes
	rm -f nginx/conf.d/*.conf
	find envs -mindepth 1 -delete
	find logs -mindepth 1 -maxdepth 1 ! -name 'archived' -exec rm -rf {} +
	find logs/archived -mindepth 1 -delete

ensure-dirs:
	mkdir -p envs logs logs/archived nginx/conf.d monitor
