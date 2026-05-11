# DevOps Sandbox

`devops-sandbox` is a self-service platform for spinning up short-lived application environments on a single Linux VM. Each environment gets its own container, dedicated Docker network, dynamic Nginx route, health monitoring, log capture, TTL-based cleanup, and manual outage simulation.

The idea is a miniature internal Heroku with a chaos toggle:
- create an isolated environment on demand
- route traffic to it through Nginx
- watch health and logs
- simulate failure modes
- recover or let the TTL destroy it automatically

## Architecture

```text
                                  +----------------------+
                                  |      Operator        |
                                  | make / curl / API    |
                                  +----------+-----------+
                                             |
                                             v
                             +---------------+----------------+
                             |  Control API (FastAPI in Docker)|
                             |  wraps create/destroy/outage    |
                             +---------------+----------------+
                                             |
                                             v
                    +------------------------+------------------------+
                    |                  Docker Host                    |
                    |                                                 |
                    |   +-------------------+                         |
Incoming Traffic -->|   |   Nginx Container |                         |
 :8080              |   | Front Door / Edge |                         |
                    |   +---------+---------+                         |
                    |             |                                   |
                    |     includes generated                          |
                    |     nginx/conf.d/<env-id>.conf                  |
                    |             |                                   |
                    |    +--------+---------+                         |
                    |    | Shared Edge Net  |                         |
                    |    +--------+---------+                         |
                    |             |                                   |
                    |   +---------+----------+      +----------------+----------+
                    |   | Sandbox App        |      | Sandbox App               |
                    |   | env-abc123         |      | env-def456                |
                    |   | label: sandbox.env |      | label: sandbox.env        |
                    |   +---------+----------+      +----------------+----------+
                    |             |                                   |
                    |   +---------+----------+      +----------------+----------+
                    |   | Dedicated Net      |      | Dedicated Net             |
                    |   | devops-sandbox-... |      | devops-sandbox-...        |
                    |   +--------------------+      +---------------------------+
                    |                                                 |
                    |   State + Ops                                    |
                    |   - envs/<env-id>.json                           |
                    |   - logs/<env-id>/app.log                        |
                    |   - logs/<env-id>/health.log                     |
                    |   - logs/cleanup.log                             |
                    |                                                 |
                    |   Background Workers                             |
                    |   - cleanup_daemon.sh                            |
                    |   - monitor/health_poller.sh                     |
                    +-------------------------------------------------+

Observability:
- Prometheus scrapes `GET /metrics` from the control API
- Promtail ships container logs to Loki
- Grafana can visualize both metrics and logs
```

## Repository Layout

```text
devops-sandbox/
├── platform/          # create_env.sh, destroy_env.sh, cleanup_daemon.sh, API, worker helpers
├── nginx/             # nginx.conf + conf.d/ generated per-environment configs
├── monitor/           # health poller + Prometheus/Loki/Promtail/Grafana configs
├── logs/              # runtime logs, gitignored except placeholders
├── envs/              # runtime state files, gitignored except placeholders
├── Makefile
└── README.md
```

## Stack

- Docker
- Docker Compose
- Nginx
- Bash + Makefile
- Python 3 / FastAPI
- Prometheus
- Loki
- Promtail
- Grafana
- Optional: GitHub Actions CI

## Prerequisites

Run this project on a single Linux VM with:

- Docker Engine installed and running
- Docker Compose v2 available as `docker compose`
- GNU `make`
- Bash
- Python 3
- Internet access to pull container images on first run

Recommended open ports:

- `8080` for Nginx
- `9090` for Prometheus
- `3100` for Loki
- `3000` for Grafana

## Configuration

All runtime configuration lives in `.env`. Do not commit it.

Create it from the example:

```bash
cp .env.example .env
```

Current example variables:

```env
PROJECT_NAME=devops-sandbox
NGINX_PORT=8080
API_PORT=8080/api
EDGE_NETWORK=devops-sandbox-edge
SANDBOX_BASE_URL=http://localhost:8080
DEFAULT_TTL_MINUTES=30
SANDBOX_INTERNAL_PORT=8080/api
LOKI_URL=http://localhost:3100
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=admin
```

What they do:

- `PROJECT_NAME`: prefix used for long-running platform containers and networks
- `NGINX_PORT`: host port exposed by Nginx
- `API_PORT`: internal port used by the control API container
- `EDGE_NETWORK`: shared Docker network used by Nginx and all active sandbox apps
- `SANDBOX_BASE_URL`: base URL printed by the lifecycle scripts
- `DEFAULT_TTL_MINUTES`: fallback TTL when none is supplied
- `SANDBOX_INTERNAL_PORT`: internal port exposed by the sandbox app container
- `LOKI_URL`: Loki base URL used by the API and CLI log queries
- `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD`: Grafana login credentials

## Full Setup

### 1. Clone the repository

```bash
git clone <your-repo-url> devops-sandbox
cd devops-sandbox
```

### 2. Create your environment file

```bash
cp .env.example .env
```

If your VM host is not using localhost for demo access, update `SANDBOX_BASE_URL` in `.env`.

Example:

```env
SANDBOX_BASE_URL=http://your-vm-ip:8080
```

### 3. Start the platform

```bash
make up
```

This starts:

- the Nginx front door
- the control API
- Prometheus
- Loki
- Promtail
- Grafana
- the cleanup daemon in the background
- the health poller in the background

### 4. Confirm the platform is alive

```bash
curl http://localhost:8080/health
curl http://localhost:8080/api/health
```

### 5. Create your first environment

```bash
make create
```

You will be prompted for:

- environment name
- TTL in minutes

At the end, the script prints:

- environment ID
- environment URL
- TTL

## Quick Start in Under 5 Commands

```bash
git clone <your-repo-url> devops-sandbox
cd devops-sandbox
cp .env.example .env
make up
make create
```

## Network Approach

Nginx is the front door for every environment.

This project uses two layers of networking:

1. A shared edge network
   - Nginx lives here
   - every sandbox app is attached here
   - this is how Nginx can proxy to active sandbox containers

2. A dedicated network per environment
   - created by `create_env.sh`
   - removed by `destroy_env.sh`
   - keeps each sandbox environment isolated by design

Routing is path-based:

```text
http://<host>:8080/envs/<env-id>/
```

On create:

- a file is written to `nginx/conf.d/<env-id>.conf`
- Nginx is reloaded

On destroy:

- the file is deleted
- Nginx is reloaded again

## Environment Lifecycle

### Create

`platform/create_env.sh <name> [ttl_minutes]`

What it does:

- generates a unique environment ID
- creates a dedicated Docker network
- starts the demo app container
- labels the app with `sandbox.env=<env-id>`
- writes state to `envs/<env-id>.json`
- generates Nginx routing config
- reloads Nginx
- labels the app for Loki log collection
- prints URL and TTL

The state file is written atomically through a temporary file and rename.

### Destroy

`platform/destroy_env.sh <env-id>`

What it does:

- reads the environment state
- stops and removes all containers with the environment label
- removes the dedicated Docker network
- deletes the generated Nginx config
- reloads Nginx
- exports app logs from Loki to `logs/archived/<env-id>/app.log`
- archives health logs to `logs/archived/<env-id>/`
- deletes the state file

## Auto Cleanup

`platform/cleanup_daemon.sh` runs forever and checks `envs/*.json` every 60 seconds.

If:

```text
now > created_at + ttl
```

it destroys the expired environment automatically.

Cleanup actions are timestamped in:

```text
logs/cleanup.log
```

`make up` starts the daemon in the background with `nohup`.

## Health Monitoring

`monitor/health_poller.sh` checks each active environment every 30 seconds.

It hits:

```text
GET /health
```

for each active environment and writes results to:

```text
logs/<env-id>/health.log
```

Each line contains:

- timestamp
- HTTP status
- latency in milliseconds

After 3 consecutive failures:

- environment status is set to `degraded`
- a warning is printed
- a warning is also written to `logs/health-monitor.log`

## Log Shipping

This project uses Approach B with Loki.

Runtime collection:

- Promtail reads container logs from the Docker socket
- Loki stores the log streams
- sandbox containers are labeled with `sandbox.env=<env-id>`
- `make logs ENV=<env-id>` queries Loki by the `sandbox_env` label for active environments

On environment destruction:

- app logs are exported from Loki to `logs/archived/<env-id>/app.log`
- health logs are archived with the rest of the environment files

Query logs by environment:

```bash
make logs ENV=<env-id>
```

## Outage Simulation

Use the platform script directly:

```bash
bash platform/simulate_outage.sh --env <env-id> --mode crash
```

Or use the Make target:

```bash
make simulate ENV=<env-id> MODE=crash
```

Supported modes:

- `crash`: `docker kill` the sandbox app container
- `pause`: `docker pause` the sandbox app container
- `network`: disconnect the sandbox app from the shared edge network
- `recover`: undo the last simulated outage
- `stress`: optional CPU stress using `stress-ng` if available in the app container

Safety guard:

- the script refuses to run if the target is not a sandbox app container
- it will not run against Nginx or daemon-like containers

## Control API

Base URL:

```text
http://localhost:8080/api
```

Endpoints:

- `POST /envs` → create environment
- `GET /envs` → list active environments with TTL remaining
- `DELETE /envs/{id}` → destroy environment
- `GET /envs/{id}/logs` → last 100 lines of app log
- `GET /envs/{id}/health` → last 10 health check results
- `POST /envs/{id}/outage` → trigger outage simulation

Example create request:

```bash
curl -X POST http://localhost:8080/api/envs \
  -H "Content-Type: application/json" \
  -d '{"name":"demo","ttl_minutes":30}'
```

Example outage request:

```bash
curl -X POST http://localhost:8080/api/envs/<env-id>/outage \
  -H "Content-Type: application/json" \
  -d '{"mode":"crash"}'
```

## Make Targets

Available targets:

- `make up`  
  Starts Nginx, the control API, the cleanup daemon, and the health poller.

- `make down`  
  Stops workers, destroys all active environments, and shuts down platform containers.

- `make create`  
  Prompts for environment name and TTL, then creates a new sandbox environment.

- `make destroy ENV=<env-id>`  
  Destroys one environment.

- `make logs ENV=<env-id>`  
  Queries Loki for active envs and reads archived `app.log` after destroy.

- `make health`  
  Prints all current environment statuses with TTL remaining and failure counts.

- `make simulate ENV=<env-id> MODE=<mode>`  
  Runs outage simulation.

- `make clean`  
  Wipes generated configs, state files, logs, and archives after shutting everything down.

## Full Demo Walkthrough

### 1. Start the platform

```bash
make up
```

### 2. Create an environment

```bash
make create
```

Example output:

```text
Environment created
ID: env-20260510120000-abc123
URL: http://localhost:8080/envs/env-20260510120000-abc123/
TTL: 30 minutes
```

### 3. Open the environment

Visit:

```text
http://localhost:8080/envs/<env-id>/
```

### 4. Check health

```bash
curl http://localhost:8080/envs/<env-id>/health
curl http://localhost:8080/api/envs/<env-id>/health
make health
```

### 5. Inspect logs

```bash
make logs ENV=<env-id>
```

### 6. Simulate an outage

```bash
make simulate ENV=<env-id> MODE=crash
```

You can also try:

```bash
make simulate ENV=<env-id> MODE=pause
make simulate ENV=<env-id> MODE=network
```

### 7. Observe degradation

Within 90 seconds, the health monitor should detect repeated failures and mark the environment as degraded.

Check:

```bash
make health
curl http://localhost:8080/api/envs
tail -f logs/<env-id>/health.log
```

### 8. Recover

```bash
make simulate ENV=<env-id> MODE=recover
```

### 9. Confirm health returns

```bash
make health
curl http://localhost:8080/envs/<env-id>/health
```

### 10. Destroy manually or wait for TTL expiry

Manual destroy:

```bash
make destroy ENV=<env-id>
```

Automatic destroy:

- wait until the TTL expires
- cleanup daemon removes the environment
- check `logs/cleanup.log`

### 11. Confirm archived logs

```bash
make logs ENV=<env-id>
```

After destroy, logs should be available from:

```text
logs/archived/<env-id>/
```

## Observability

Prometheus, Loki, Promtail, and Grafana are included in the default Compose stack and start with `make up`.

Access:

- Prometheus: `http://localhost:9090`
- Loki: `http://localhost:3100`
- Grafana: `http://localhost:3000`

Grafana credentials:

```text
<GRAFANA_ADMIN_USER> / <GRAFANA_ADMIN_PASSWORD>
```

Prometheus scrapes:

```text
GET /metrics
```

from the control API, and Grafana is pre-provisioned with both Prometheus and Loki datasources.

Active app logs can also be queried from the CLI:

```bash
make logs ENV=<env-id>
```

## CI

GitHub Actions CI is included in:

```text
.github/workflows/ci.yml
```

It validates:

- Python syntax
- Docker Compose config
- shell scripts with `shellcheck`

## Known Limitations

- Built for a single Linux VM only
- Uses path-based routing instead of wildcard subdomains
- `stress` mode requires `stress-ng` inside the sandbox app image
- The cleanup daemon and health poller run on the VM host, not as containers
- The API container shells out to Docker-backed lifecycle scripts, so Docker socket permissions on the Linux VM must be correct
- This project assumes a Linux host with standard `bash`, `nohup`, `mktemp`, and `/var/run/docker.sock`
