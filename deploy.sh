#!/bin/bash
set -e

echo "=========================================================="
echo "    Deploying Open-Source BMS Lab Environment             "
echo "    Stack: BACnet Sim + Node-RED + InfluxDB + Grafana     "
echo "=========================================================="

# 1. Clean up any previous runs
echo "=== 1. Cleaning up existing lab containers & volumes ==="
docker compose down --volumes --remove-orphans 2>/dev/null || true

# 2. Create directory hierarchy
echo "=== 2. Creating directory structure ==="
mkdir -p bacnet-sim nodered-data influxdb-data grafana-data grafana-provisioning/datasources

# 3. Generate Docker Compose configuration
echo "=== 3. Writing docker-compose.yml ==="
cat << 'EOF' > docker-compose.yml
services:
  bacnet-sim:
    build: ./bacnet-sim
    container_name: bms-bacnet-sim
    ports:
      - "47808:47808/udp"
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "5"

  nodered:
    build: ./nodered-data
    container_name: bms-nodered
    ports:
      - "1880:1880"
    volumes:
      - ./nodered-data:/data
    depends_on:
      - bacnet-sim
      - influxdb
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "5"

  influxdb:
    image: influxdb:2.7-alpine
    container_name: bms-influxdb
    ports:
      - "8086:8086"
    environment:
      - DOCKER_INFLUXDB_INIT_MODE=setup
      - DOCKER_INFLUXDB_INIT_USERNAME=admin
      - DOCKER_INFLUXDB_INIT_PASSWORD=adminpassword123
      - DOCKER_INFLUXDB_INIT_ORG=bms_org
      - DOCKER_INFLUXDB_INIT_BUCKET=bms_history
      - DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=bms-super-secret-auth-token
    volumes:
      - ./influxdb-data:/var/lib/influxdb2
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "5"

  grafana:
    image: grafana/grafana-oss:latest
    container_name: bms-grafana
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
    volumes:
      - ./grafana-data:/var/lib/grafana
      - ./grafana-provisioning/datasources:/etc/grafana/provisioning/datasources
    depends_on:
      - influxdb
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "5"
EOF

# 4. Generate Python BACnet/IP Simulator & Dockerfile
echo "=== 4. Generating BACnet/IP Virtual Device Simulator ==="
cat << 'EOF' > bacnet-sim/bacnet_sim.py
import time
import random
from threading import Thread
from bacpypes.core import run
from bacpypes.app import BIPSimpleApplication
from bacpypes.local.device import LocalDeviceObject
from bacpypes.object import AnalogInputObject

device = LocalDeviceObject(
    objectName="Virtual_AHU_Controller",
    objectIdentifier=("device", 1234),
    maxApduLengthAccepted=1476,
    segmentationSupported="segmentedBoth",
    vendorIdentifier=15,
)

room_temp_ai = AnalogInputObject(
    objectIdentifier=("analogInput", 1),
    objectName="RoomTemperature",
    presentValue=21.5,
    description="Zone 1 Ambient Room Temperature"
)

app = BIPSimpleApplication(device, "0.0.0.0:47808")
app.add_object(room_temp_ai)

def simulate_thermodynamics():
    while True:
        time.sleep(5)
        try:
            current_val = room_temp_ai.presentValue
            delta = random.uniform(-0.35, 0.35)
            new_val = round(max(19.5, min(25.5, current_val + delta)), 2)
            room_temp_ai.presentValue = new_val
            print(f"[BACnet Sim] AI:1 Room Temperature -> {new_val} °C", flush=True)
        except Exception as e:
            print(f"[BACnet Sim Error] {e}", flush=True)

if __name__ == "__main__":
    sim_thread = Thread(target=simulate_thermodynamics, daemon=True)
    sim_thread.start()
    print("=== Virtual BACnet/IP Controller active on UDP 47808 ===", flush=True)
    run()
EOF

cat << 'EOF' > bacnet-sim/Dockerfile
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir bacpypes
COPY bacnet_sim.py .
CMD ["python", "bacnet_sim.py"]
EOF

# 5. Generate Custom Node-RED Dockerfile & Pre-Configured Ingestion Flows
echo "=== 5. Building Node-RED Container Image & Pre-Baked Ingestion Flows ==="
cat << 'EOF' > nodered-data/Dockerfile
FROM nodered/node-red:latest
USER root
RUN npm install node-red-contrib-bacnet node-red-contrib-influxdb
USER node-red
EOF

cat << 'EOF' > nodered-data/flows.json
[
    {
        "id": "bms_tab",
        "type": "tab",
        "label": "BMS Ingestion Engine"
    },
    {
        "id": "bacnet_client",
        "type": "BACnet-Client",
        "name": "BACnet Client",
        "interface": "0.0.0.0",
        "port": "47808",
        "broadcastAddress": "255.255.255.255",
        "adpuTimeout": "3000"
    },
    {
        "id": "bacnet_device",
        "type": "BACnet-Device",
        "name": "Virtual AHU Controller",
        "deviceAddress": "bms-bacnet-sim"
    },
    {
        "id": "temp_instance",
        "type": "BACnet-Instance",
        "name": "RoomTempInstance",
        "instanceAddress": "1"
    },
    {
        "id": "influx_config",
        "type": "influxdb",
        "hostname": "bms-influxdb",
        "port": "8086",
        "protocol": "http",
        "database": "bms_history",
        "name": "BMS InfluxDB Storage",
        "usetls": false,
        "tls": "",
        "influxdbVersion": "2.0",
        "url": "http://bms-influxdb:8086",
        "timeout": "10",
        "rejectUnauthorized": false
    },
    {
        "id": "poll_timer",
        "type": "inject",
        "z": "bms_tab",
        "name": "Poll Every 10s",
        "props": [{"p": "payload"}],
        "repeat": "10",
        "once": true,
        "onceDelay": "1",
        "payloadType": "date",
        "x": 140,
        "y": 120,
        "wires": [["bacnet_read_node"]]
    },
    {
        "id": "bacnet_read_node",
        "type": "BACnet-Read",
        "z": "bms_tab",
        "name": "Read AI:1 Room Temp",
        "objectType": "0",
        "instance": "temp_instance",
        "propertyId": "85",
        "device": "bacnet_device",
        "server": "bacnet_client",
        "multipleRead": false,
        "x": 370,
        "y": 120,
        "wires": [["format_influx_node"]]
    },
    {
        "id": "format_influx_node",
        "type": "function",
        "z": "bms_tab",
        "name": "Format for InfluxDB v2",
        "func": "let rawVal = msg.payload.values ? msg.payload.values[0].value : msg.payload;\nlet temp = parseFloat(rawVal);\n\nmsg.payload = [{\n    measurement: \"environment\",\n    fields: {\n        room_temp: temp\n    },\n    tags: {\n        device: \"Virtual_AHU_1\",\n        location: \"Server_Room_Zone_1\"\n    },\n    timestamp: new Date()\n}];\nreturn msg;",
        "outputs": 1,
        "noerr": 0,
        "x": 610,
        "y": 120,
        "wires": [["influx_out_node"]]
    },
    {
        "id": "influx_out_node",
        "type": "influxdb batch",
        "z": "bms_tab",
        "influxdb": "influx_config",
        "bucket": "bms_history",
        "org": "bms_org",
        "query": "",
        "token": "bms-super-secret-auth-token",
        "name": "Write to bms_history",
        "x": 840,
        "y": 120,
        "wires": []
    }
]
EOF

# 6. Auto-Provision Grafana Data Source
echo "=== 6. Provisioning Grafana Auto-Connection to InfluxDB ==="
cat << 'EOF' > grafana-provisioning/datasources/influxdb.yaml
apiVersion: 1
datasources:
  - name: InfluxDB-BMS
    type: influxdb
    access: proxy
    url: http://bms-influxdb:8086
    jsonData:
      version: Flux
      organization: bms_org
      defaultBucket: bms_history
    secureJsonData:
      token: bms-super-secret-auth-token
EOF

# 7. Relax Permissions for Mounted Directories
chmod -R 777 nodered-data influxdb-data grafana-data grafana-provisioning 2>/dev/null || true

# 8. Build & Launch Stack
echo "=== 7. Building & Launching Docker Containers ==="
docker compose build
docker compose up -d

echo "=========================================================="
echo "    SUCCESS! BMS Testing Lab is Online and Active.        "
echo "=========================================================="
echo " Services & Endpoints:"
echo "   - Node-RED Flow Editor: http://localhost:1880"
echo "   - InfluxDB UI:           http://localhost:8086 (admin / adminpassword123)"
echo "   - Grafana UI:            http://localhost:3000 (admin / admin)"
echo "   - BACnet/IP Simulator:   UDP Port 47808"
echo "=========================================================="
