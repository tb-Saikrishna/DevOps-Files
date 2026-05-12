#!/usr/bin/env bash

set -euo pipefail

# =========================================================
# INIT
# =========================================================

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_COMPOSE_FILE="$CURRENT_DIR/docker-compose.yaml"
IMAGE_DIR="$CURRENT_DIR/images"
DOCKER_DEP_DIR_22="$CURRENT_DIR/docker-offline-dep-22"
DOCKER_DEP_DIR_24="$CURRENT_DIR/docker-offline-dep-24"

echo "=================================================="
echo "          tb-SIEM OFFLINE INSTALLER"
echo "=================================================="

# =========================================================
# ROOT CHECK
# =========================================================

check_root_user() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "Error: Run this script as root."
    exit 1
  fi
}

# =========================================================
# HELPERS
# =========================================================

is_ip_address() {
    local value="$1"
    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

ask_yes_no() {
  local prompt="$1"
  local answer
  while true; do
    read -r -p "$prompt (y/n): " answer
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo "Please enter y or n." ;;
    esac
  done
}

upsert_host_entry() {
    local ip="$1"
    local host="$2"
    local tmp_file
    tmp_file="$(mktemp)"
    awk -v h="$host" '$2 == h {next} {print}' /etc/hosts > "$tmp_file"
    printf "%s %s\n" "$ip" "$host" >> "$tmp_file"
    cat "$tmp_file" > /etc/hosts
    rm -f "$tmp_file"
}


# =========================================================
# DOCKER INSTALL
# =========================================================

install_docker_packages() {
  local dep_dir="$1"
  local packages=("docker-ce-cli" "docker-ce" "containerd.io" "docker-buildx-plugin" "docker-compose-plugin")
  local package package_dir deb_file

  for package in "${packages[@]}"; do
    package_dir="$dep_dir/$package"
    if [[ ! -d "$package_dir" ]]; then
      echo "Error: Missing package directory $package_dir"
      exit 1
    fi
    for deb_file in "$package_dir"/*.deb; do
      [[ -e "$deb_file" ]] || continue
      echo "Installing $(basename "$deb_file")"
      dpkg -i "$deb_file"
    done
  done
}

install_docker_if_requested() {
  if ask_yes_no "Do you want to install Docker from offline packages"; then
    if [[ -f /etc/os-release ]]; then
      # shellcheck disable=SC1091
      . /etc/os-release
      if [[ "$ID" == "ubuntu" && "$VERSION_ID" == "22.04" ]]; then
        install_docker_packages "$DOCKER_DEP_DIR_22"
      elif [[ "$ID" == "ubuntu" && "$VERSION_ID" == "24.04" ]]; then
        install_docker_packages "$DOCKER_DEP_DIR_24"
      else
        echo "Error: Only Ubuntu 22.04 and 24.04 are supported for offline Docker install."
        exit 1
      fi
    else
      echo "Error: /etc/os-release not found."
      exit 1
    fi
    systemctl enable docker
    systemctl start docker
  fi
}

# =========================================================
# LOAD IMAGES
# =========================================================
load_images_from_directory() {
  local loaded_any="false"
  local image_file
  local extract_dir
  local extracted_tar

  echo "Loading images from: $IMAGE_DIR"
  if [[ -d "$IMAGE_DIR" ]]; then
    for image_file in "$IMAGE_DIR"/*.tar "$IMAGE_DIR"/*.tar.gz; do
      [[ -e "$image_file" ]] || continue

      if [[ "$image_file" == *.tar.gz ]]; then
        extract_dir="$(mktemp -d)"
        echo "Extracting archive: $image_file"
        tar -xzf "$image_file" -C "$extract_dir"

        for extracted_tar in "$extract_dir"/*.tar; do
          [[ -e "$extracted_tar" ]] || continue
          echo "Loading extracted image: $extracted_tar"
          docker load -i "$extracted_tar"
          loaded_any="true"
        done

        rm -rf "$extract_dir"
      else
        echo "Loading image file: $image_file"
        docker load -i "$image_file"
        loaded_any="true"
      fi
    done
  fi

  if [[ "$loaded_any" == "false" ]]; then
    echo "No image archive found in image directory. Trying fallback tar in project root."
    if [[ -f "$CURRENT_DIR/my-node-base_24.5.0.tar" ]]; then
      docker load -i "$CURRENT_DIR/my-node-base_24.5.0.tar"
    fi
  fi
}


# =========================================================
# HOSTNAMES
# =========================================================

declare -A HOSTNAMES
HOSTNAMES[tbsiem]="tbsiem.tech-bridge.biz"
HOSTNAMES[opensearch]="opensearch.tech-bridge.biz"
HOSTNAMES[cybersio]="cybersio.tech-bridge.biz"
HOSTNAMES[tbsoar]="tbsoar.tech-bridge.biz"

echo ""
echo "=================================================="
echo "          HOSTNAME CONFIGURATION"
echo "=================================================="

read -r -p "Enter tbSIEM hostname [${HOSTNAMES[tbsiem]}]: " input
[[ -n "$input" ]] && HOSTNAMES[tbsiem]="$input"

read -r -p "Enter OpenSearch hostname [${HOSTNAMES[opensearch]}]: " input
[[ -n "$input" ]] && HOSTNAMES[opensearch]="$input"

read -r -p "Enter CyberSIO hostname [${HOSTNAMES[cybersio]}]: " input
[[ -n "$input" ]] && HOSTNAMES[cybersio]="$input"

read -r -p "Enter tbSOAR hostname [${HOSTNAMES[tbsoar]}]: " input
[[ -n "$input" ]] && HOSTNAMES[tbsoar]="$input"

# =========================================================
# PEER CONFIGURATION
# =========================================================

echo ""
echo "=================================================="
echo "          TBSIEM PEER CONFIGURATION"
echo "=================================================="

read -r -p "Enter IP for ${HOSTNAMES[tbsiem]}: " MAIN_TBSIEM_IP
while [[ -z "$MAIN_TBSIEM_IP" ]]; do
    echo "IP cannot be empty"
    read -r -p "Enter IP for ${HOSTNAMES[tbsiem]}: " MAIN_TBSIEM_IP
done

while true; do
    read -r -p "How many peers do you want? (1-4): " PEER_COUNT
    if [[ "$PEER_COUNT" =~ ^[1-4]$ ]]; then
        break
    fi
    echo "Please enter only 1, 2, 3, or 4"
done

declare -a PEER_NAMES
declare -a PEER_IPS

for (( i=1; i<=PEER_COUNT; i++ )); do
    PEER_NAME="tbsiem${i}.tech-bridge.biz"
    read -r -p "Enter IP for ${PEER_NAME}: " PEER_IP
    while [[ -z "$PEER_IP" ]]; do
        echo "IP cannot be empty"
        read -r -p "Enter IP for ${PEER_NAME}: " PEER_IP
    done
    PEER_NAMES+=("$PEER_NAME")
    PEER_IPS+=("$PEER_IP")
done

# =========================================================
# /etc/hosts
# =========================================================

echo ""
echo "Updating /etc/hosts..."

sed -i '/tbsiem.tech-bridge.biz/d' /etc/hosts
sed -i '/tbsiem[0-9].tech-bridge.biz/d' /etc/hosts
echo "${MAIN_TBSIEM_IP} ${HOSTNAMES[tbsiem]}" >> /etc/hosts

for (( i=0; i<PEER_COUNT; i++ )); do
    echo "${PEER_IPS[$i]} ${PEER_NAMES[$i]}" >> /etc/hosts
done

echo "/etc/hosts updated successfully"

# =========================================================
# EXTRA HOSTNAME MAPPINGS
# =========================================================

echo ""
echo "=================================================="
echo "          EXTRA HOSTNAME MAPPINGS"
echo "=================================================="

read -r -p "Enter IP for ${HOSTNAMES[opensearch]}: " OPENSEARCH_IP
read -r -p "Enter IP for ${HOSTNAMES[cybersio]}: " CYBERSIO_IP
read -r -p "Enter IP for ${HOSTNAMES[tbsoar]}: " TBSOAR_IP

upsert_host_entry "$OPENSEARCH_IP" "${HOSTNAMES[opensearch]}"
upsert_host_entry "$CYBERSIO_IP" "${HOSTNAMES[cybersio]}"
upsert_host_entry "$TBSOAR_IP" "${HOSTNAMES[tbsoar]}"

# =========================================================
# PEERS ENV
# =========================================================

PEERS_ENV=""

for (( i=0; i<PEER_COUNT; i++ )); do
    PEER_URL="https://${PEER_NAMES[$i]}:8002"
    if [[ -z "$PEERS_ENV" ]]; then
        PEERS_ENV="$PEER_URL"
    else
        PEERS_ENV="${PEERS_ENV},${PEER_URL}"
    fi
done

# =========================================================
# DATABASE CONFIGURATION
# =========================================================

echo ""
echo "=================================================="
echo "          DATABASE CONFIGURATION"
echo "=================================================="

while true; do
    read -r -p "How many PostgreSQL hosts? : " DB_COUNT
    [[ "$DB_COUNT" =~ ^[0-9]+$ ]] && break
    echo "Invalid count"
done

DB_ENTRIES=""

for ((i=1; i<=DB_COUNT; i++)); do
    read -r -p "PostgreSQL Host IP #$i: " db_ip
    if [[ $i -eq 1 ]]; then
        DB_ENTRIES="\"$db_ip\""
    else
        DB_ENTRIES="$DB_ENTRIES,\"$db_ip\""
    fi
done

DB_HOST_ARRAY="[$DB_ENTRIES]"

# =========================================================
# CERTIFICATES
# =========================================================

run_certificate_if_requested() {
    local cert_script="$CURRENT_DIR/certificate.sh"
    if ask_yes_no "Do you want to generate certificates"; then
        [[ -f "$cert_script" ]] || { echo "certificate.sh not found"; exit 1; }
        chmod +x "$cert_script"
        bash "$cert_script"
    fi
}

# =========================================================
# DB SCRIPT
# =========================================================

run_db_if_requested() {
    local db_script="$CURRENT_DIR/db.sh"
    if ask_yes_no "Do you want to run db.sh"; then
        [[ -f "$db_script" ]] || { echo "db.sh not found"; exit 1; }
        chmod +x "$db_script"
        bash "$db_script"
    fi
}

# =========================================================
# UPDATE COMPOSE FILE
# =========================================================

replace_compose_values() {
    local compose_backup
    compose_backup="$DOCKER_COMPOSE_FILE.old.$(date +%Y%m%d%H%M%S)"
    cp "$DOCKER_COMPOSE_FILE" "$compose_backup"
    echo "Backup created: $compose_backup"

    # PGHOST
    sed -E -i "s|^([[:space:]]*PGHOST:).*|\\1 '$DB_HOST_ARRAY'|g" "$DOCKER_COMPOSE_FILE"

    # PEERS
    sed -E -i "s|^([[:space:]]*PEERS:).*|\\1 ${PEERS_ENV}|g" "$DOCKER_COMPOSE_FILE"

    # HOST_IP
    sed -E -i "s|HOST_IP=.*|HOST_IP=${HOSTNAMES[tbsiem]}|g" "$DOCKER_COMPOSE_FILE"

    # TBSIEM BASE URL
    sed -E -i "s|TBSIEM_BASE_URL:.*|TBSIEM_BASE_URL: https://${HOSTNAMES[tbsiem]}:8003|g" "$DOCKER_COMPOSE_FILE"

    # OpenSearch
    sed -E -i "s|SERVER_IP:.*|SERVER_IP: '[\"https://${HOSTNAMES[opensearch]}:9200\"]'|g" "$DOCKER_COMPOSE_FILE"

    # API Gateway
    sed -E -i "s|API_GATEWAY_BASE_URL:.*|API_GATEWAY_BASE_URL: https://${HOSTNAMES[cybersio]}:9007|g" "$DOCKER_COMPOSE_FILE"

    # SOAR
    sed -E -i "s|SOAR_BASE_URL:.*|SOAR_BASE_URL: https://${HOSTNAMES[tbsoar]}:5001|g" "$DOCKER_COMPOSE_FILE"
}

# =========================================================
# RUN DOCKER
# =========================================================

run_docker() {
    docker compose -f "$DOCKER_COMPOSE_FILE" down || true
    docker compose -f "$DOCKER_COMPOSE_FILE" up -d
    docker compose -f "$DOCKER_COMPOSE_FILE" ps
}

# =========================================================
# MAIN
# =========================================================

main() {
    check_root_user
    install_docker_packages
    install_docker_if_requested
    if ask_yes_no "Do you want to load Docker images"; then
        load_images_from_directory
    fi
    run_certificate_if_requested
    run_db_if_requested
    replace_compose_values
    run_docker
    echo ""
    echo "=================================================="
    echo "          tb-SIEM INSTALLATION COMPLETED"
    echo "=================================================="
}

main "$@"
