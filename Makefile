SHELL := /bin/bash

PROJECT_NAME ?= devops-sandbox

.PHONY: up down create destroy logs health simulate clean ensure-dirs

up: ensure-dirs
	docker compose up -d --build nginx api

down:
	docker compose down --remove-orphans

create:
	@printf "Step 1 scaffold only: environment creation will be implemented in Step 2.\n"

destroy:
	@printf "Step 1 scaffold only: environment destruction will be implemented in Step 2.\n"

logs:
	@printf "Step 1 scaffold only: per-environment logs will be implemented in Step 2.\n"

health:
	@printf "Step 1 scaffold only: sandbox health summary will be implemented in Step 3.\n"

simulate:
	@printf "Step 1 scaffold only: outage simulation will be implemented later.\n"

clean: down
	@printf "Step 1 scaffold only: deep cleanup will be implemented after lifecycle scripts land.\n"

ensure-dirs:
	mkdir -p envs logs logs/archived nginx/conf.d monitor
