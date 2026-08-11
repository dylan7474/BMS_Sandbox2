# Open-Source Building Management System (BMS) Testing Lab

This repository provides an automated deployment script for a 100% open-source Building Management System (BMS) integration, storage, and visualization lab.

It replicates the core architectural layers of proprietary commercial BMS supervisors, such as Tridium Niagara or Honeywell Trend IQ Vision, on a single Linux host using Docker Compose and without proprietary software licenses.

## System Architecture

The sandbox contains four components that communicate over a private Docker bridge network:

1. **Virtual Field Controller (`bacnet-sim`)** — A Python-based BACnet/IP device emulator using `bacpypes`. It runs on UDP port `47808` and acts as a zero-hardware endpoint that emits fluctuating ambient room-temperature data (Analog Input, Instance 1) every five seconds.
2. **Integration Middleware (`nodered`)** — The supervisor engine. It includes BACnet and InfluxDB nodes, polls the virtual controller, normalizes readings, and formats them for the time-series database.
3. **Time-Series Historian (`influxdb`)** — An InfluxDB OSS v2 container that receives telemetry from Node-RED and stores it in the `bms_history` bucket.
4. **Central Dashboard UI (`grafana`)** — A Grafana front end that is automatically provisioned with an InfluxDB data source for Flux queries and real-time or historical trends.

## Prerequisites

- **Operating system:** Debian, Ubuntu Server, or another modern Linux distribution
- **Docker Engine:** Version 20.10 or later
- **Docker Compose:** Version 2.0 or later (`docker compose`)
- **Permissions:** Ability to execute Bash scripts and run Docker commands

Confirm that Docker is available before deploying:

```bash
docker --version
docker compose version
```

## Deployment

The `deploy.sh` script generates the directory structure and configuration files, creates the Node-RED flows, and launches the Docker containers.

1. Clone this repository and enter its directory.
2. Run the deployment script:

   ```bash
   ./deploy.sh
   ```

> [!WARNING]
> The script begins by tearing down existing containers and volumes associated with this Compose project. Back up any data that you want to retain before running it again.

## Services and Endpoints

After deployment completes, the following services are available:

| Service | Container name | Address or port | Default credentials |
| --- | --- | --- | --- |
| Node-RED | `bms-nodered` | `http://<HOST_IP>:1880` | N/A |
| InfluxDB | `bms-influxdb` | `http://<HOST_IP>:8086` | `admin` / `adminpassword123` |
| Grafana | `bms-grafana` | `http://<HOST_IP>:3000` | `admin` / `admin` |
| BACnet simulator | `bms-bacnet-sim` | UDP `47808` | N/A |

When accessing a service locally on the host, replace `<HOST_IP>` with `localhost`.

## Verifying the Deployment

### 1. Check the Virtual Field Controller

Verify that the BACnet simulator is emitting randomized temperature data:

```bash
docker compose logs --follow bacnet-sim
```

You should see temperature updates every five seconds. Press <kbd>Ctrl</kbd>+<kbd>C</kbd> to stop following the logs; the container will remain running.

### 2. Check the Integration Pipeline

1. Open Node-RED at `http://<HOST_IP>:1880`.
2. Locate the preconfigured **BMS Ingestion Engine** flow.
3. Open the **Debug sidebar** (the bug icon in the upper-right corner) to monitor writes to InfluxDB.

### 3. Build a Live Dashboard

The deployment script automatically provisions Grafana with an InfluxDB connection. To visualize the data:

1. Open Grafana at `http://<HOST_IP>:3000` and sign in with username `admin` and password `admin`.
2. Navigate to **Dashboards** > **New Dashboard** > **Add visualization**.
3. Select the `InfluxDB-BMS` data source.
4. Ensure that the query language is **Flux**, then enter the following query to plot a moving window of room-temperature data:

   ```flux
   from(bucket: "bms_history")
     |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
     |> filter(fn: (r) => r["_measurement"] == "environment")
     |> filter(fn: (r) => r["_field"] == "room_temp")
     |> aggregateWindow(every: 10s, fn: mean, createEmpty: false)
     |> yield(name: "room_temperature")
   ```

5. In the right sidebar, change the panel type to **Time series**.
6. Under **Standard options**, set the unit to **Celsius (°C)**.
7. Set the dashboard auto-refresh interval to **5s**.
8. Select **Save**.

## Operations

Start or recreate the complete stack:

```bash
docker compose up --detach
```

Stop the stack while preserving persistent data:

```bash
docker compose down
```

Remove the stack and all persistent historical data:

```bash
docker compose down --volumes --remove-orphans
```

## Security Warning

This environment is a **testing and learning sandbox**, not a production-hardened deployment. It uses default hardcoded passwords, exposes industrial protocol simulators and dashboards without authentication or TLS, and relaxes directory permissions for container access.

Do not deploy the sandbox on an internet-exposed server without appropriate firewall rules, TLS termination, access controls, and replacement credentials.
