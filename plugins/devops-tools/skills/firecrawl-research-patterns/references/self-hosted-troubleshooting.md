# Firecrawl Troubleshooting

## Symptom: API Container Stopped

**Root Cause**: Docker restart policy was `no` (default). Container received SIGINT and didn't restart.

**Diagnosis**:

```bash
# Check container status
ssh littleblack 'docker ps -a --filter "name=firecrawl"'

# Check restart policy
ssh littleblack 'docker inspect --format "{{.Name}}: {{.HostConfig.RestartPolicy.Name}}" $(docker ps -a --filter "name=firecrawl" -q)'
```

**Fix**: Add `restart: unless-stopped` to ALL services in `docker-compose.yaml`:

```yaml
# ~/firecrawl/docker-compose.yaml
x-common-service: &common-service
  networks:
    - backend
  restart: unless-stopped # CRITICAL: Add this line
  logging:
    driver: "json-file"
    options:
      max-size: "1G"
      max-file: "4"

services:
  playwright-service:
    <<: *common-service
    # ... rest of config

  api:
    <<: *common-service
    # ... rest of config

  redis:
    <<: *common-service
    # ... rest of config

  rabbitmq:
    <<: *common-service
    # ... rest of config
```

**Apply Fix**:

```bash
ssh littleblack 'cd ~/firecrawl && docker compose up -d --force-recreate'
```

**Verify**:

```bash
ssh littleblack 'docker inspect --format "{{.Name}}: RestartPolicy={{.HostConfig.RestartPolicy.Name}}" $(docker ps -a --filter "name=firecrawl" -q)'
# All should show: RestartPolicy=unless-stopped
```

## Symptom: Scraper Wrapper Not Responding

**Diagnosis**:

```bash
ssh littleblack "systemctl --user status firecrawl-scraper"
```

**Fix**:

```bash
ssh littleblack "systemctl --user restart firecrawl-scraper"
```

## Symptom: Caddy File Server Down

**Diagnosis**:

```bash
ssh littleblack "systemctl --user status caddy-firecrawl"
curl -I http://littleblack:8080/
```

**Fix**:

```bash
ssh littleblack "systemctl --user restart caddy-firecrawl"
```

## Symptom: Tailscale Unreachable

**Diagnosis**:

```bash
# From local machine
tailscale ping littleblack

# Check Tailscale status
tailscale status
```

**Fix**: Re-authorize device in Tailscale admin console if needed.
