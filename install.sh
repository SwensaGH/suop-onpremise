#!/bin/bash
# ============================================================
#  Serveiz Utility Operations Platform (SUOP) — On-Premise
#  K3s Installer
# ============================================================

err="Error in installation. Please report to support.swensa.com and attach the /tmp/suop_setup.log file"
log="/tmp/suop_setup.log"
>$log

BASE=/opt

# ============================================================
# Install required packages
# ============================================================
echo "Checking required packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update >>$log 2>&1

PACKAGES=(curl git jq net-tools)
for pkg in "${PACKAGES[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        echo "Installing $pkg..."
        apt-get install -y "$pkg" >>$log 2>&1
        if [ $? -ne 0 ]; then
            echo "Error: installing $pkg failed" >>$log
            echo "$err"; exit -100
        fi
    fi
done

# ============================================================
# Gather platform admin info (Swensa staff account only)
# Customers are added later via the Swensa Admin portal.
# ============================================================
while true; do
    echo -n "Enter Swensa platform admin email: "
    read email
    echo -n "Re-enter email: "
    read confirmemail
    [ "$email" == "$confirmemail" ] && break
    echo "Emails don't match. Try again."
done

# ============================================================
# Generate secrets
# ============================================================
echo "Generating secrets..."
mysql_password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16; echo '')
pg_password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16; echo '')
admin_password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13; echo '')
internal_key=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32; echo '')
jwt_secret=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 64; echo '')

# ============================================================
# Install K3s
# ============================================================
echo "------------------------------------------"
echo "Installing K3s. Please wait..."
echo "------------------------------------------"
echo "insecure" > ~/.curlrc
curl -s https://get.k3s.io > temp_install_k3s.sh
chmod +x temp_install_k3s.sh
./temp_install_k3s.sh >>$log 2>&1
if [ $? -ne 0 ]; then
    echo "Error: K3s installation failed" >>$log
    echo "$err"; exit -1
fi
rm -f temp_install_k3s.sh

echo "Configuring kubectl..."
mkdir -p ~/.kube
cp /etc/rancher/k3s/k3s.yaml ~/.kube/config >>$log 2>&1
if [ $? -ne 0 ]; then
    echo "Error: /etc/rancher/k3s/k3s.yaml missing" >>$log
    echo "$err"; exit -2
fi
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# ============================================================
# Clone SUOP yaml manifests
# ============================================================
echo "Installing SUOP manifests..."
echo "------------------------------------------"
mkdir -p ${BASE}/suop
git clone https://github.com/SwensaGH/SUOP-OnPremise ${BASE}/suop >>$log 2>&1
if [ $? -ne 0 ]; then
    echo "Error: git clone SUOP-OnPremise failed" >>$log
    echo "$err"; exit -4
fi

# ============================================================
# Create host data directories
# ============================================================
mkdir -p ${BASE}/suop/mysqldata
mkdir -p ${BASE}/suop/postgresdata
mkdir -p ${BASE}/suop/kafkadata

# ============================================================
# Substitute generated secrets into YAML files
# ============================================================
echo "Applying configuration..."

YAML_DIR="${BASE}/suop/yaml"

# MySQL password
sed -i "s/_GENERATE_PASSWORD_/${mysql_password}/g" ${YAML_DIR}/mysql.yaml
sed -i "s/_GENERATE_PASSWORD_/${mysql_password}/g" ${YAML_DIR}/ubs.yaml
sed -i "s/_GENERATE_PASSWORD_/${mysql_password}/g" ${YAML_DIR}/swensa-admin.yaml

# Postgres password
sed -i "s/_GENERATE_PG_PASSWORD_/${pg_password}/g" ${YAML_DIR}/postgres.yaml
sed -i "s/_GENERATE_PG_PASSWORD_/${pg_password}/g" ${YAML_DIR}/mdm.yaml

# Shared internal key
sed -i "s/_INTERNAL_KEY_/${internal_key}/g" ${YAML_DIR}/mdm.yaml
sed -i "s/_INTERNAL_KEY_/${internal_key}/g" ${YAML_DIR}/ubs.yaml
sed -i "s/_INTERNAL_KEY_/${internal_key}/g" ${YAML_DIR}/swensa-admin.yaml

# JWT secret
sed -i "s/_JWT_SECRET_/${jwt_secret}/g" ${YAML_DIR}/mdm.yaml
sed -i "s/_JWT_SECRET_/${jwt_secret}/g" ${YAML_DIR}/ubs.yaml
sed -i "s/_JWT_SECRET_/${jwt_secret}/g" ${YAML_DIR}/swensa-admin.yaml
sed -i "s/_JWT_SECRET_/${jwt_secret}/g" ${YAML_DIR}/serveiz-cloud.yaml

# ============================================================
# Pull latest image tags from Docker Hub
# ============================================================
echo "Fetching latest image versions..."

fetch_tag() {
    local repo=$1
    local filter=$2
    curl -s "https://hub.docker.com/v2/repositories/${repo}/tags" \
        | jq -r '.results[].name' \
        | grep "${filter}" \
        | sort | tail -n 1
}

mdm_image=$(fetch_tag "swensadocker/serveiz-mdm" "main")
ubs_image=$(fetch_tag "swensadocker/ubs" "main")
cloud_image=$(fetch_tag "swensadocker/serveiz-cloud" "main")
admin_image=$(fetch_tag "swensadocker/swensa-admin" "main")
hes_image=$(fetch_tag "swensadocker/hes-simulator" "main")

echo "  MDM:           ${mdm_image}"
echo "  UBS:           ${ubs_image}"
echo "  ServeizCloud:  ${cloud_image}"
echo "  SwensaAdmin:   ${admin_image}"
echo "  HES Simulator: ${hes_image}"

sed -i "s/_MDMIMAGE_/${mdm_image}/g"     ${YAML_DIR}/mdm.yaml
sed -i "s/_UBSIMAGE_/${ubs_image}/g"     ${YAML_DIR}/ubs.yaml
sed -i "s/_CLOUDIMAGE_/${cloud_image}/g" ${YAML_DIR}/serveiz-cloud.yaml
sed -i "s/_ADMINIMAGE_/${admin_image}/g" ${YAML_DIR}/swensa-admin.yaml
sed -i "s/_HESIMAGE_/${hes_image}/g"     ${YAML_DIR}/hes-simulator.yaml

# ============================================================
# Detect public IP (AWS EC2 metadata, falls back to ifconfig)
# ============================================================
echo "Detecting public IP..."
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null)
ip=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null)

# Fallback: use first non-loopback IP
if [ -z "$ip" ] || echo "$ip" | grep -q "404\|Not Found"; then
    ip=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
fi
echo "Server IP: $ip"
sed -i "s/_IPADDRESS_/${ip}/g" ${YAML_DIR}/traefik.yaml

# ============================================================
# Apply Kubernetes manifests (in dependency order)
# ============================================================
echo "------------------------------------------"
echo "Starting infrastructure services..."
echo "------------------------------------------"

apply() {
    local file=$1
    local desc=$2
    kubectl apply -f "${YAML_DIR}/${file}" >>$log 2>&1
    if [ $? -ne 0 ]; then
        echo "Error: ${file} failed" >>$log
        echo "$err"; exit -10
    fi
    echo "  ✓ ${desc}"
}

apply persistent.yaml   "Persistent volumes"
apply configmap.yaml    "ConfigMaps"
apply zookeeper.yaml    "ZooKeeper"
apply kafka.yaml        "Kafka"
apply mysql.yaml        "MySQL"
apply postgres.yaml     "PostgreSQL (TimescaleDB)"

echo "Waiting 60s for databases to initialize..."
sleep 60

echo "------------------------------------------"
echo "Starting application services..."
echo "------------------------------------------"
apply mdm.yaml              "MDM"
apply ubs.yaml              "UBS"
apply serveiz-cloud.yaml    "ServeizCloud"
apply swensa-admin.yaml     "Swensa Admin"
apply hes-simulator.yaml    "HES Simulator"

# Traefik CRDs + ingress
echo "Configuring ingress..."
kubectl apply -f https://raw.githubusercontent.com/traefik/traefik/v3.3/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml >>$log 2>&1
sleep 10
apply traefik.yaml "Traefik ingress routes"

# ============================================================
# Wait for all pods to be Running
# ============================================================
echo "------------------------------------------"
echo "Waiting for all pods to be ready..."
echo "------------------------------------------"
TIMEOUT=300
ELAPSED=0
while true; do
    not_ready=$(kubectl get pods 2>/dev/null | grep -v "Running\|Completed\|NAME" | wc -l)
    if [ "$not_ready" -eq 0 ]; then
        echo ""
        echo "All pods are running."
        break
    fi
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo ""
        echo "Warning: Timed out waiting for pods. Check 'kubectl get pods' for status."
        break
    fi
    echo -n "."
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

# Give apps extra time to finish startup
echo "Waiting 60s for application startup..."
sleep 60

# ============================================================
# Create Swensa platform admin account
# (Customers are NOT provisioned here — use Swensa Admin UI)
# ============================================================
echo "------------------------------------------"
echo "Creating Swensa platform admin account..."
echo "------------------------------------------"

ADMIN_URL="http://${ip}/admin/api"

# Wait for swensa-admin to be responsive
echo -n "Waiting for Swensa Admin to be ready"
for i in $(seq 1 30); do
    status=$(curl -s -o /dev/null -w "%{http_code}" "${ADMIN_URL}/actuator/health" 2>/dev/null)
    if [ "$status" == "200" ]; then
        echo " ready."
        break
    fi
    echo -n "."
    sleep 5
done

# Register the Swensa staff admin user
http_response=$(curl -s -X POST "${ADMIN_URL}/auth/register" \
    -H 'Content-Type: application/json' \
    -d "{
        \"email\": \"${email}\",
        \"password\": \"${admin_password}\",
        \"username\": \"swensa_admin\"
    }")
echo "  Admin registration response: ${http_response}" >>$log

if echo "$http_response" | grep -qi "success\|created\|id"; then
    echo "  ✓ Platform admin account created"
else
    echo "  Warning: Could not auto-create admin account. Log in to Swensa Admin and register manually." >&2
    echo "  Response was: ${http_response}" >&2
fi

# ============================================================
# Setup cron jobs for maintenance
# ============================================================
CRON_JOBS=(
    "*/5 * * * * kubectl get pods >> /tmp/suop_pod_status.log 2>&1"
    "30 05 * * * kubectl get pods --all-namespaces >> /tmp/suop_daily_status.log 2>&1"
)

CURRENT_CRON=$(crontab -u root -l 2>/dev/null || echo "")
for JOB in "${CRON_JOBS[@]}"; do
    if ! echo "$CURRENT_CRON" | grep -Fq "$JOB"; then
        CURRENT_CRON+=$'\n'"$JOB"
    fi
done
echo "$CURRENT_CRON" | crontab -u root -

# ============================================================
# Print summary
# ============================================================
echo ""
echo "============================================================"
echo "  SUOP Installation Complete!"
echo "============================================================"
echo ""
echo "  Swensa Admin Portal:  http://${ip}/admin/"
echo "  UBS (Billing):        http://${ip}/"
echo "  MDM API:              http://${ip}/mdm/"
echo "  Field Service:        http://${ip}/cloud/"
echo ""
echo "  Swensa Staff Login:"
echo "    Email:    ${email}"
echo "    Password: ${admin_password}"
echo ""
echo "  Next step: Log in to Swensa Admin and create your first"
echo "  customer tenant. The platform is ready to host multiple"
echo "  customers — each is provisioned independently via the UI."
echo ""
echo "  DB credentials saved to: /opt/suop/.credentials"
echo "============================================================"

# Save credentials to file for recovery
cat > /opt/suop/.credentials <<CREDS
# SUOP Platform Credentials
# Generated during installation — keep this file secure (chmod 600)
#
# These are PLATFORM-LEVEL secrets. Customer accounts are managed
# via the Swensa Admin portal at http://${ip}/admin/

SWENSA_ADMIN_EMAIL=${email}
SWENSA_ADMIN_PASSWORD=${admin_password}
MYSQL_ROOT_PASSWORD=${mysql_password}
POSTGRES_PASSWORD=${pg_password}
INTERNAL_KEY=${internal_key}
JWT_SECRET=${jwt_secret}
SERVER_IP=${ip}
CREDS
chmod 600 /opt/suop/.credentials

echo "Installation log: $log"
