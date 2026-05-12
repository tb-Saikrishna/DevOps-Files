#!/usr/bin/env bash
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_COMPOSE_FILE="$CURRENT_DIR/docker-compose.yaml"
IMAGE_DIR="$CURRENT_DIR/images"
DOCKER_DEP_DIR_22="$CURRENT_DIR/docker-offline-dep-22"
DOCKER_DEP_DIR_24="$CURRENT_DIR/docker-offline-dep-24"


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

check_root_user() {
  [[ "$EUID" -eq 0 ]] || { echo "Run as root"; exit 1; }
}

install_pkg_dir() {
  local dir="$1"
  local pkg deb
  for pkg in docker-ce-cli docker-ce containerd.io docker-buildx-plugin docker-compose-plugin; do
    for deb in "$dir/$pkg"/*.deb; do
      [[ -e "$deb" ]] || continue
      dpkg -i "$deb"
    done
  done
}

install_docker_if_requested() {
  if ask_yes_no "Do you want to install Docker from offline packages"; then
    . /etc/os-release
    case "$VERSION_ID" in
      "22.04") install_pkg_dir "$DOCKER_DEP_DIR_22" ;;
      "24.04") install_pkg_dir "$DOCKER_DEP_DIR_24" ;;
      *) echo "Unsupported OS"; exit 1 ;;
    esac
    systemctl start docker
    systemctl enable docker
  fi
}

load_images() {
  local image_file extract_dir extracted_tar loaded_any="false"
  if [[ -d "$IMAGE_DIR" ]]; then
    for image_file in "$IMAGE_DIR"/*.tar "$IMAGE_DIR"/*.tar.gz; do
      [[ -e "$image_file" ]] || continue
      if [[ "$image_file" == *.tar.gz ]]; then
        extract_dir="$(mktemp -d)"
        tar -xzf "$image_file" -C "$extract_dir"
        for extracted_tar in "$extract_dir"/*.tar; do
          [[ -e "$extracted_tar" ]] || continue
          docker load -i "$extracted_tar"
          loaded_any="true"
        done
        rm -rf "$extract_dir"
      else
        docker load -i "$image_file"
        loaded_any="true"
      fi
    done
  fi

  if [[ "$loaded_any" == "false" ]]; then
    for image_file in "$CURRENT_DIR"/*.tar "$CURRENT_DIR"/*.tar.gz; do
      [[ -e "$image_file" ]] || continue
      docker load -i "$image_file"
    done
  fi
}

# ===============================
# TBSIEM PEER CONFIGURATION
# ===============================

echo ""
echo "======================================"
echo " TBSIEM PEER CONFIGURATION "
echo "======================================"
echo ""

# Main domain
read -p "Enter IP for tbsiem.tech-bridge.biz: " MAIN_TBSIEM_IP

while [ -z "$MAIN_TBSIEM_IP" ]; do
    echo "IP cannot be empty"
    read -p "Enter IP for tbsiem.tech-bridge.biz: " MAIN_TBSIEM_IP
done

# Ask peer count
while true; do

    read -p "How many peers do you want? (1-4): " PEER_COUNT

    if [[ "$PEER_COUNT" =~ ^[1-4]$ ]]; then
        break
    fi

    echo "Please enter only 1, 2, 3, or 4"

done

declare -a PEER_NAMES
declare -a PEER_IPS

# Collect peer IPs
for (( i=1; i<=PEER_COUNT; i++ ))
do

    PEER_NAME="tbsiem${i}.tech-bridge.biz"

    read -p "Enter IP for ${PEER_NAME}: " PEER_IP

    while [ -z "$PEER_IP" ]; do
        echo "IP cannot be empty"
        read -p "Enter IP for ${PEER_NAME}: " PEER_IP
    done

    PEER_NAMES+=("$PEER_NAME")
    PEER_IPS+=("$PEER_IP")

done

# ===============================
# UPDATE /etc/hosts
# ===============================

echo ""
echo "Updating /etc/hosts..."

# Remove old entries
sed -i '/tbsiem.tech-bridge.biz/d' /etc/hosts
sed -i '/tbsiem[0-9].tech-bridge.biz/d' /etc/hosts

# Main domain entry
echo "${MAIN_TBSIEM_IP} tbsiem.tech-bridge.biz" >> /etc/hosts

# Peer entries
for (( i=0; i<PEER_COUNT; i++ ))
do
    echo "${PEER_IPS[$i]} ${PEER_NAMES[$i]}" >> /etc/hosts
done

echo ""
echo "/etc/hosts updated successfully"

# ===============================
# GENERATE PEERS ENV VARIABLE
# ===============================

PEERS_ENV=""

for (( i=0; i<PEER_COUNT; i++ ))
do

    PEER_URL="https://${PEER_NAMES[$i]}:8002"

    if [ -z "$PEERS_ENV" ]; then
        PEERS_ENV="$PEER_URL"
    else
        PEERS_ENV="${PEERS_ENV},${PEER_URL}"
    fi

done

echo ""
echo "Generated PEERS:"
echo "$PEERS_ENV"

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

collect_hostnames() {
  local value
  read -r -p "Portal hostname/FQDN for tbIAM [$HOSTNAME_IAM]: " value
  if [[ -n "${value// }" ]]; then
    is_ip_address "$value" && { echo "Please enter hostname, not IP."; exit 1; }
    HOSTNAME_IAM="$value"
  fi
  read -r -p "Core hostname/FQDN for tbIAM [$HOSTNAME_CORE]: " value
  if [[ -n "${value// }" ]]; then
    is_ip_address "$value" && { echo "Please enter hostname, not IP."; exit 1; }
    HOSTNAME_CORE="$value"
  fi

  read -r -p "IP for $HOSTNAME_IAM: " IAM_IP
  read -r -p "IP for $HOSTNAME_CORE: " CORE_IP

  if ask_yes_no "Do you want to update /etc/hosts for these hostnames"; then
    upsert_host_entry "$IAM_IP" "$HOSTNAME_IAM"
    upsert_host_entry "$CORE_IP" "$HOSTNAME_CORE"
  fi
}

collect_db_inputs() {
  read -r -p "How many PGHOST DB IPs for tbiam-backend: " DB_COUNT
  [[ "$DB_COUNT" =~ ^[0-9]+$ ]] || { echo "Invalid DB count"; exit 1; }
  DB_ENTRIES=""
  for ((i=1; i<=DB_COUNT; i++)); do
    read -r -p "PGHOST IP #$i: " db_ip
    if [[ $i -eq 1 ]]; then
      DB_ENTRIES="\"$db_ip\""
      KC_DB_IP="$db_ip"
    else
      DB_ENTRIES="$DB_ENTRIES,\"$db_ip\""
    fi
  done

  # Keep these fixed defaults to avoid unnecessary prompts.
  # PGUSER=tbiam, PGPASSWORD=admin, PGDATABASE=tbiam
  # KEYCLOAK USERNAME=admin, KEYCLOAK PASSWORD=admin
  # CLIENT SECRET stays empty unless manually edited in compose.
}
replace_compose_values() {

  local key old_host new_host
  local compose_backup="$DOCKER_COMPOSE_FILE.old.$(date +%Y%m%d%H%M%S)"

  cp "$DOCKER_COMPOSE_FILE" "$compose_backup"

  echo "Backup created: $compose_backup"

  # ==========================================
  # Replace default hostnames with custom ones
  # ==========================================

  for key in "${!DEFAULT_HOSTNAMES[@]}"; do

    old_host="${DEFAULT_HOSTNAMES[$key]}"
    new_host="${HOSTNAMES[$key]}"

    sed -i "s|$old_host|$new_host|g" "$DOCKER_COMPOSE_FILE"

  done

  # ==========================================
  # PostgreSQL Hosts
  # ==========================================

  sed -E -i \
  "s|^([[:space:]]*PGHOST:).*|\\1 '$DB_HOST_ARRAY'|g" \
  "$DOCKER_COMPOSE_FILE"

  # ==========================================
  # PEERS
  # ==========================================

  sed -E -i \
  "s|^([[:space:]]*PEERS:).*|\\1 ${PEERS_ENV}|g" \
  "$DOCKER_COMPOSE_FILE"

  # ==========================================
  # HOST IP / DOMAIN
  # ==========================================

  sed -E -i \
  "s|^([[:space:]]*-[[:space:]]HOST_IP=).*|\\1${HOSTNAMES[tbsiem]}|g" \
  "$DOCKER_COMPOSE_FILE"

  # ==========================================
  # TBSIEM BASE URL
  # ==========================================

  sed -E -i \
  "s|^([[:space:]]*TBSIEM_BASE_URL:).*|\\1 https://${HOSTNAMES[tbsiem]}:8003|g" \
  "$DOCKER_COMPOSE_FILE"

  # ==========================================
  # OpenSearch URL
  # ==========================================

  sed -E -i \
  "s|^([[:space:]]*SERVER_IP:).*|\\1 '$SERVER_IP_JSON'|g" \
  "$DOCKER_COMPOSE_FILE"

  # ==========================================
  # Wazuh Manager URL
  # ==========================================

  sed -E -i \
  "s|^([[:space:]]*TBSIEM_CLIENT_API_URLS:).*|\\1 https://${WAZUH_MANAGER_HOST}:55000|g" \
  "$DOCKER_COMPOSE_FILE"

  # ==========================================
  # API Gateway URL
  # ==========================================

  sed -E -i \
  "s|^([[:space:]]*API_GATEWAY_BASE_URL:).*|\\1 https://${CYBERSIO_HOST}:9007|g" \
  "$DOCKER_COMPOSE_FILE"

  # ==========================================
  # SOAR URL
  # ==========================================

  sed -E -i \
  "s|^([[:space:]]*SOAR_BASE_URL:).*|\\1 https://${SOAR_HOST}:5001|g" \
  "$DOCKER_COMPOSE_FILE"

}


run_db_if_requested() {
  local db_script="$CURRENT_DIR/db.sh"
  if ask_yes_no "Do you want to run tbIAM db.sh"; then
    [[ -f "$db_script" ]] || { echo "db.sh not found in $CURRENT_DIR"; exit 1; }
    chmod +x "$db_script"
    bash "$db_script"
  fi
}

run_certificate_if_requested() {
  local cert_script="$CURRENT_DIR/certificate.sh"
  if ask_yes_no "Do you want to generate tbIAM certificate files"; then
    [[ -f "$cert_script" ]] || { echo "certificate.sh not found in $CURRENT_DIR"; exit 1; }
    chmod +x "$cert_script"
    bash "$cert_script" "$HOSTNAME_IAM" "$HOSTNAME_CORE"
  fi
}

run_docker() {
  docker compose -f "$DOCKER_COMPOSE_FILE" down || true
  docker compose -f "$DOCKER_COMPOSE_FILE" up -d
  docker compose -f "$DOCKER_COMPOSE_FILE" ps
}

main() {
  check_root_user
  install_docker_if_requested
  if ask_yes_no "Do you want to load Docker images"; then
    load_images
  fi
  collect_hostnames
  collect_db_inputs
  run_certificate_if_requested
  run_db_if_requested
  create_docker_compose_file
  run_docker
  echo "tbIAM setup completed."
}

main "$@"
