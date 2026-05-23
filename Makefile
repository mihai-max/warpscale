COMPOSE ?= docker compose
SERVICE ?= warp-exit

.PHONY: build up down restart logs shell status trace ps

build:
	$(COMPOSE) build

up:
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

restart:
	$(COMPOSE) restart

logs:
	$(COMPOSE) logs -f $(SERVICE)

ps:
	$(COMPOSE) ps

shell:
	$(COMPOSE) exec $(SERVICE) bash

# Run the WARP healthcheck inside the container (expects warp=on).
status:
	$(COMPOSE) exec $(SERVICE) /usr/local/bin/healthcheck.sh && echo "WARP: up" || echo "WARP: down"

# Full Cloudflare trace through the WARP tunnel.
trace:
	$(COMPOSE) exec $(SERVICE) curl -fsS --interface wg0 https://www.cloudflare.com/cdn-cgi/trace
