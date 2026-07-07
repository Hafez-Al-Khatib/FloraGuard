.PHONY: build up down logs dev-up dev-down test lint fmt certs

build:
	docker compose build

up:
	docker compose up -d

down:
	docker compose down -v

dev-up:
	docker compose -f docker-compose.dev.yml up --build -d

dev-down:
	docker compose -f docker-compose.dev.yml down -v

logs:
	docker compose logs -f api

dev-logs:
	docker compose -f docker-compose.dev.yml logs -f api

certs:
	bash mosquitto/config/gen-certs.sh

test:
	cd app && python -m pytest

lint:
	cd app && ruff check .

fmt:
	cd app && ruff format .
