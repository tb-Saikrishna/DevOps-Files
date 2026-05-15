#!/usr/bin/env bash

set -euo pipefail

# ==========================================
# INIT
# ==========================================

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOCKER_COMPOSE_FILE="$CURRENT_DIR/docker-compose.yaml"

IMAGE_DIR="$CURRENT_DIR/images"

DOCKER_DEP_DIR_22="$CURRENT_DIR/docker-offline-dep-22"
DOCKER_DEP_DIR_24="$CURRENT_DIR/docker-offline-dep-24"

# ==========================================
# HELPERS
# ==========================================

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

# ==========================================
# ROOT CHECK
# ==========================================

check_root_user() {
	[[ "$EUID" -eq 0 ]] || {
		echo "Run as root"
		exit 1
	}
}

# ==========================================
# DOCKER INSTALL
# ==========================================

install_pkg_dir() {
	local dir="$1"
	local pkg
	local deb

	for pkg in \
		docker-ce-cli \
		docker-ce \
		containerd.io \
		docker-buildx-plugin \
		docker-compose-plugin
	do
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
			"22.04")
				install_pkg_dir "$DOCKER_DEP_DIR_22"
				;;
			"24.04")
				install_pkg_dir "$DOCKER_DEP_DIR_24"
				;;
			*)
				echo "Unsupported OS"
				exit 1
				;;
		esac

		systemctl enable docker
		systemctl start docker
	fi
}

# ==========================================
# LOAD IMAGES
# ==========================================

load_images() {
	local image_file
	local extract_dir
	local extracted_tar

	if [[ -d "$IMAGE_DIR" ]]; then
		for image_file in "$IMAGE_DIR"/*.tar "$IMAGE_DIR"/*.tar.gz; do
			[[ -e "$image_file" ]] || continue

			if [[ "$image_file" == *.tar.gz ]]; then
				extract_dir="$(mktemp -d)"
				tar -xzf "$image_file" -C "$extract_dir"

				for extracted_tar in "$extract_dir"/*.tar; do
					[[ -e "$extracted_tar" ]] || continue
					docker load -i "$extracted_tar"
				done

				rm -rf "$extract_dir"
			else
				docker load -i "$image_file"
			fi
		done
	fi
}

# ==========================================
# DEFAULT HOSTNAMES
# ==========================================

declare -A DEFAULT_HOSTNAMES=(
	[tbsoar]="tbsoar.tech-bridge.biz"
	[tbsiem]="tbsiem.tech-bridge.biz"
	[tbueba]="tbueba.tech-bridge.biz"
)

declare -A HOSTNAMES=(
	[tbsoar]="tbsoar.tech-bridge.biz"
	[tbsiem]="tbsiem.tech-bridge.biz"
	[tbueba]="tbueba.tech-bridge.biz"
)

# ==========================================
# HOSTNAME COLLECTION
# ==========================================

collect_hostnames() {
	local value

	echo ""
	echo "======================================"
	echo " HOSTNAME CONFIGURATION "
	echo "======================================"
	echo ""

	for key in "${!HOSTNAMES[@]}"; do
		read -r -p "Enter hostname for ${key} [${HOSTNAMES[$key]}]: " value

		if [[ -n "${value// }" ]]; then
			is_ip_address "$value" && {
				echo "Please enter hostname, not IP."
				exit 1
			}

			HOSTNAMES[$key]="$value"
		fi
	done

	echo ""

	read -r -p "Enter IP for ${HOSTNAMES[tbsoar]}: " TBSOAR_IP
	read -r -p "Enter IP for ${HOSTNAMES[tbsiem]}: " TBSIEM_IP
	read -r -p "Enter IP for ${HOSTNAMES[tbueba]}: " TBUEBA_IP

	if ask_yes_no "Do you want to update /etc/hosts"; then
		upsert_host_entry "$TBSOAR_IP" "${HOSTNAMES[tbsoar]}"
		upsert_host_entry "$TBSIEM_IP" "${HOSTNAMES[tbsiem]}"
		upsert_host_entry "$TBUEBA_IP" "${HOSTNAMES[tbueba]}"
	fi
}

# ==========================================
# DATABASE INPUTS
# ==========================================

collect_db_inputs() {
	echo ""
	echo "======================================"
	echo " DATABASE CONFIGURATION "
	echo "======================================"
	echo ""

	read -r -p "Enter PostgreSQL Host IP: " PGHOST

	read -r -p "Enter PostgreSQL Username [postgres]: " PGUSER
	PGUSER="${PGUSER:-postgres}"

	read -r -s -p "Enter PostgreSQL Password [admin]: " PGPASSWORD
	echo ""
	PGPASSWORD="${PGPASSWORD:-admin}"

	read -r -p "Enter PostgreSQL Database [tbsoar]: " PGDATABASE
	PGDATABASE="${PGDATABASE:-tbsoar}"

	read -r -p "Enter PostgreSQL Port [5432]: " PGPORT
	PGPORT="${PGPORT:-5432}"
}

# ==========================================
# OPTIONAL CONFIGS
# ==========================================

collect_optional_inputs() {
	echo ""
	echo "======================================"
	echo " OPTIONAL CONFIGURATION "
	echo "======================================"
	echo ""

	read -r -p "Enter SOAR Version [1.2.1]: " SOAR_VERSION
	SOAR_VERSION="${SOAR_VERSION:-1.2.1}"

	read -r -p "Enter SIEM API KEYS [9a8d7a9d7a9d,8a7d6c5b4a3b]: " SIEM_API_KEYS
	SIEM_API_KEYS="${SIEM_API_KEYS:-9a8d7a9d7a9d,8a7d6c5b4a3b}"

	read -r -p "Enter Alert Email Recipient [devendra.singh@tech-bridge.biz]: " ALERT_EMAIL
	ALERT_EMAIL="${ALERT_EMAIL:-devendra.singh@tech-bridge.biz}"
}

# ==========================================
# COMPOSE MUTATION
# ==========================================

replace_compose_values() {
	local compose_backup

	compose_backup="$DOCKER_COMPOSE_FILE.old.$(date +%Y%m%d%H%M%S)"

	cp "$DOCKER_COMPOSE_FILE" "$compose_backup"

	echo ""
	echo "Backup created:"
	echo "$compose_backup"

	# ==========================================
	# Replace default hostnames
	# ==========================================

	for key in "${!DEFAULT_HOSTNAMES[@]}"; do
		sed -i \
			"s|${DEFAULT_HOSTNAMES[$key]}|${HOSTNAMES[$key]}|g" \
			"$DOCKER_COMPOSE_FILE"
	done

	# ==========================================
	# HOST IP
	# ==========================================

	sed -E -i \
		"s|HOST_IP=.*|HOST_IP=${HOSTNAMES[tbsoar]}|g" \
		"$DOCKER_COMPOSE_FILE"

	# ==========================================
	# PostgreSQL
	# ==========================================

	sed -E -i \
		"s|PGHOST=.*|PGHOST=${PGHOST}|g" \
		"$DOCKER_COMPOSE_FILE"

	sed -E -i \
		"s|PGUSER=.*|PGUSER=${PGUSER}|g" \
		"$DOCKER_COMPOSE_FILE"

	sed -E -i \
		"s|PGPASSWORD=.*|PGPASSWORD=${PGPASSWORD}|g" \
		"$DOCKER_COMPOSE_FILE"

	sed -E -i \
		"s|PGDATABASE=.*|PGDATABASE=${PGDATABASE}|g" \
		"$DOCKER_COMPOSE_FILE"

	sed -E -i \
		"s|PGPORT=.*|PGPORT=${PGPORT}|g" \
		"$DOCKER_COMPOSE_FILE"

	# ==========================================
	# SOAR VERSION
	# ==========================================

	sed -E -i \
		"s|SOAR_VERSION=.*|SOAR_VERSION=${SOAR_VERSION}|g" \
		"$DOCKER_COMPOSE_FILE"

	# ==========================================
	# SIEM API KEYS
	# ==========================================

	sed -E -i \
		"s|SIEM_API_KEYS=.*|SIEM_API_KEYS=${SIEM_API_KEYS}|g" \
		"$DOCKER_COMPOSE_FILE"

	# ==========================================
	# EMAIL
	# ==========================================

	sed -E -i \
		"s|SEND_EMAIL_TO=.*|SEND_EMAIL_TO=${ALERT_EMAIL}|g" \
		"$DOCKER_COMPOSE_FILE"

	# ==========================================
	# SIEM URL
	# ==========================================

	sed -E -i \
		"s|AGENT_SUMMARY_BASE_URL=.*|AGENT_SUMMARY_BASE_URL=https://${HOSTNAMES[tbsiem]}:3001/v1/agent/summary/list|g" \
		"$DOCKER_COMPOSE_FILE"

	# ==========================================
	# UEBA URL
	# ==========================================

	sed -E -i \
		"s|UEBA_IP_RISK_SCORE_URL=.*|UEBA_IP_RISK_SCORE_URL=https://${HOSTNAMES[tbueba]}:1443/tbueba/IPriskscores|g" \
		"$DOCKER_COMPOSE_FILE"

	# ==========================================
	# AUTH USERS URL
	# ==========================================

	sed -E -i \
		"s|TBSOAR_AUTH_USERS_URL=.*|TBSOAR_AUTH_USERS_URL=https://${HOSTNAMES[tbsoar]}:5002/api/auth/users|g" \
		"$DOCKER_COMPOSE_FILE"

	# ==========================================
	# ANSIBLE TARGET
	# ==========================================

	sed -E -i \
		"s|ANSIBLE_TARGET_HOST=.*|ANSIBLE_TARGET_HOST=${HOSTNAMES[tbsoar]}|g" \
		"$DOCKER_COMPOSE_FILE"
}

# ==========================================
# OPTIONAL DB SCRIPT
# ==========================================

run_db_if_requested() {
	local db_script="$CURRENT_DIR/db.sh"

	if ask_yes_no "Do you want to run db.sh"; then
		[[ -f "$db_script" ]] || {
			echo "db.sh not found"
			exit 1
		}

		chmod +x "$db_script"
		bash "$db_script"
	fi
}

# ==========================================
# OPTIONAL CERTIFICATE
# ==========================================

run_certificate_if_requested() {
	local cert_script="$CURRENT_DIR/certificate.sh"

	if ask_yes_no "Do you want to generate certificates"; then
		[[ -f "$cert_script" ]] || {
			echo "certificate.sh not found"
			exit 1
		}

		chmod +x "$cert_script"
		bash "$cert_script" "${HOSTNAMES[tbsoar]}"
	fi
}

# ==========================================
# DOCKER RUN
# ==========================================

run_docker() {
	docker compose -f "$DOCKER_COMPOSE_FILE" down || true
	docker compose -f "$DOCKER_COMPOSE_FILE" up -d

	echo ""
	docker compose -f "$DOCKER_COMPOSE_FILE" ps
}

# ==========================================
# MAIN
# ==========================================

main() {
	check_root_user
	install_docker_if_requested

	if ask_yes_no "Do you want to load Docker images"; then
		load_images
	fi

	collect_hostnames
	collect_db_inputs
	collect_optional_inputs
	replace_compose_values
	run_certificate_if_requested
	run_db_if_requested
	run_docker

	echo ""
	echo "======================================"
	echo " TBSOAR DEPLOYMENT COMPLETED "
	echo "======================================"
	echo ""
}

main "$@"
