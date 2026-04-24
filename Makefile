.PHONY: help install dev up up-mobile check down backend mobile tb tb-stop db-migrate db-reset seed-demo reset-demo test lint bunq-bootstrap bunq-funds bunq-list supabase-up supabase-down supabase-status supabase-reset supabase-studio

help:
	@echo "Kitty — bunq Hackathon 7.0"
	@echo ""
	@echo "One-shot:"
	@echo "  make up             Boot everything (TB + backend) with preflight"
	@echo "  make up-mobile      Same as 'up', then start Expo in foreground"
	@echo "  make check          Preflight only — verify deps + .env"
	@echo "  make down           Stop backend + TigerBeetle"
	@echo ""
	@echo "Setup:"
	@echo "  make install        Install backend + mobile dependencies"
	@echo "  make supabase-up    Boot local Supabase (Postgres + Auth + Realtime + Studio)"
	@echo "  make supabase-reset Wipe & re-apply migrations"
	@echo "  make supabase-studio Open Studio in browser (http://127.0.0.1:54323)"
	@echo "  make db-migrate     Apply Supabase migrations (against a hosted DB)"
	@echo ""
	@echo "Run:"
	@echo "  make tb             Start TigerBeetle (docker-compose)"
	@echo "  make backend        Start FastAPI dev server"
	@echo "  make mobile         Start Expo (scan QR on phone)"
	@echo "  make dev            Start everything (TB + backend)"
	@echo ""
	@echo "Demo:"
	@echo "  make seed-demo      Seed 2 demo groups with realistic history"
	@echo "  make reset-demo     Wipe + reseed to known demo state (<10s)"
	@echo ""
	@echo "Quality:"
	@echo "  make test           Run verification suite"
	@echo "  make lint           Ruff + typecheck"

install:
	cd backend && uv sync || pip install -e .
	cd mobile && npm install

tb:
	docker compose up -d tigerbeetle
	@echo "TigerBeetle started on :3000"

tb-stop:
	docker compose down

backend:
	cd backend && uvicorn app.main:app --reload --port $${BACKEND_PORT:-8000}

mobile:
	cd mobile && npx expo start

dev:
	docker compose up

up:
	./start.sh

up-mobile:
	./start.sh --mobile

check:
	./start.sh --check

down:
	./stop.sh

db-migrate:
	@test -n "$$SUPABASE_DB_URL" || (echo "SUPABASE_DB_URL not set"; exit 1)
	psql "$$SUPABASE_DB_URL" -f supabase/migrations/0001_init.sql

db-reset:
	@test -n "$$SUPABASE_DB_URL" || (echo "SUPABASE_DB_URL not set"; exit 1)
	psql "$$SUPABASE_DB_URL" -f supabase/migrations/9999_reset.sql

seed-demo:
	cd backend && python -m scripts.seed_demo

reset-demo:
	cd backend && python -m scripts.reset_demo

bunq-bootstrap:
	@# Authenticate (or mint) every label in SANDBOX_USERS.md using the toolkit.
	cd backend && python -m scripts.bunq_bootstrap create-from-md

bunq-funds:
	@test -n "$(LABEL)" || (echo "usage: make bunq-funds LABEL=asha [AMOUNT=500]"; exit 1)
	cd backend && python -m scripts.bunq_bootstrap test-funds --label $(LABEL) --amount $${AMOUNT:-500}

bunq-list:
	cd backend && python -m scripts.bunq_bootstrap list

# ─ Supabase (local stack via CLI, run via npx so no global install needed) ─
supabase-up:
	npx -y supabase@latest start

supabase-down:
	npx -y supabase@latest stop

supabase-status:
	npx -y supabase@latest status

supabase-reset:
	@# Wipes the DB and re-applies every migration from supabase/migrations/
	npx -y supabase@latest db reset

supabase-studio:
	@echo "Studio: http://127.0.0.1:54323"
	@open http://127.0.0.1:54323 2>/dev/null || true

test:
	cd backend && pytest -x -q

lint:
	cd backend && ruff check . && ruff format --check .
