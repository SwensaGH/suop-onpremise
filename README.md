# SUOP On-Premise Installer

Installs the Serveiz Utility Operations Platform on a single-node K3s cluster.

## Prerequisites

- Ubuntu 22.04 LTS (or 20.04)
- Minimum: 8 vCPU, 16 GB RAM, 100 GB disk
- Root or sudo access
- Outbound internet access (Docker Hub, GitHub, K3s)

## Usage

```bash
sudo bash install.sh
```

The script will prompt for:
1. **Customer code** — short identifier, e.g. `ACME_WATER`
2. **Customer name** — display name, e.g. `Acme Water District`
3. **Platform admin email** — login email for the Swensa Admin portal

All passwords and secrets are auto-generated and saved to `/opt/suop/.credentials`.

## What gets installed

| Service         | Image                           | Port  |
|-----------------|---------------------------------|-------|
| ZooKeeper       | confluentinc/cp-zookeeper:7.6.0 | 2181  |
| Kafka           | confluentinc/cp-kafka:7.6.0     | 9092  |
| MySQL           | mysql:8.4                       | 3306  |
| PostgreSQL      | timescale/timescaledb:pg16      | 5432  |
| MDM             | swensadocker/serveiz-mdm        | 8090  |
| UBS             | swensadocker/ubs                | 8080  |
| ServeizCloud    | swensadocker/serveiz-cloud      | 8070  |
| Swensa Admin    | swensadocker/swensa-admin       | 8085  |
| HES Simulator   | swensadocker/hes-simulator      | 9090  |

## URL Map (after install)

| URL path         | Service          |
|------------------|------------------|
| `http://<IP>/`   | UBS Web UI       |
| `http://<IP>/api/` | UBS API        |
| `http://<IP>/mdm/` | MDM API        |
| `http://<IP>/admin/` | Swensa Admin |
| `http://<IP>/cloud/` | ServeizCloud |
| `http://<IP>/hes/`   | HES Simulator|

## Useful commands

```bash
# Pod status
kubectl get pods

# View logs for a service
kubectl logs -l app=ubs -f
kubectl logs -l app=mdm -f

# Restart a service
kubectl rollout restart deployment/ubs-deployment

# Check install log
cat /tmp/suop_setup.log
```
