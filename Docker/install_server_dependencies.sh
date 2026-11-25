#!/usr/bin/env bash
#
# install_server_dependencies.sh
# Install and configure Docker Engine on Debian 13 for a general-purpose
# Docker host, using /data/docker as Docker's data-root.
#
# Does NOT install host Node.js, OpenClaw, LiteLLM, Kubernetes, Swarm,
# monitoring agents, or automatic container updaters.
#
set -Eeuo pipefail
umask 027

readonly ADMIN_USER="rafael"
readonly DATA_ROOT="/data"
readonly DOCKER_DATA_ROOT="/data/docker"
readonly LOG_FILE="/var/log/install-server-dependencies.log"
readonly DOCKER_REPO_FILE="/etc/apt/sources.list.d/docker.sources"
readonly DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
readonly DOCKER_CONFIG="/etc/docker/daemon.json"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"
}

die() {
    log "ERROR: $*"
    exit 1
}

on_error() {
    local exit_code=$?
    log "ERROR: command failed at line ${BASH_LINENO[0]} (exit ${exit_code})."
    log "Review ${LOG_FILE}. No automatic rollback was attempted."
    exit "$exit_code"
}
trap on_error ERR

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run as root: bash $0"
}

preflight() {
    log "Starting Docker server dependency installation."

    [[ -r /etc/os-release ]] || die "/etc/os-release not found."
    # shellcheck disable=SC1091
    source /etc/os-release

    [[ "${ID:-}" == "debian" ]] || die "Debian is required (detected: ${ID:-unknown})."
    [[ "${VERSION_ID:-}" == "13" ]] || die "Debian 13 is required (detected: ${VERSION_ID:-unknown})."
    [[ "${VERSION_CODENAME:-}" == "trixie" ]] || die "Expected Debian codename trixie."
    id "$ADMIN_USER" >/dev/null 2>&1 || die "Admin user '${ADMIN_USER}' does not exist."

    command -v findmnt >/dev/null 2>&1 || die "findmnt is missing; install util-linux."
    mountpoint -q "$DATA_ROOT" || die "${DATA_ROOT} is not a mount point."

    local source fstype available_kb configured_root=""
    source="$(findmnt -n -o SOURCE --target "$DATA_ROOT")"
    fstype="$(findmnt -n -o FSTYPE --target "$DATA_ROOT")"

    [[ "$source" == "/dev/sdb1" ]] || die "${DATA_ROOT} is mounted from '${source}', expected /dev/sdb1."
    [[ "$fstype" == "ext4" ]] || die "${DATA_ROOT} uses '${fstype}', expected ext4."
    [[ -d "$DOCKER_DATA_ROOT" ]] || die "${DOCKER_DATA_ROOT} does not exist. Run prepare_server first."
    [[ -w "$DOCKER_DATA_ROOT" ]] || die "${DOCKER_DATA_ROOT} is not writable by root."

    available_kb="$(df -Pk "$DATA_ROOT" | awk 'NR==2 {print $4}')"
    [[ "$available_kb" =~ ^[0-9]+$ ]] || die "Could not determine free space on ${DATA_ROOT}."
    (( available_kb >= 2097152 )) || die "Less than 2 GiB is available on ${DATA_ROOT}."

    if [[ -f "$DOCKER_CONFIG" ]]; then
        command -v jq >/dev/null 2>&1 || die "jq is required to inspect ${DOCKER_CONFIG}."
        jq -e 'type == "object"' "$DOCKER_CONFIG" >/dev/null ||
            die "${DOCKER_CONFIG} is not valid JSON. Fix it before running this script."
        configured_root="$(jq -r '."data-root" // empty' "$DOCKER_CONFIG")"
        [[ -z "$configured_root" || "$configured_root" == "$DOCKER_DATA_ROOT" ]] ||
            die "${DOCKER_CONFIG} specifies data-root '${configured_root}', not '${DOCKER_DATA_ROOT}'."
    fi

    if systemctl is-active --quiet docker 2>/dev/null; then
        local current_root
        current_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
        [[ "$current_root" == "$DOCKER_DATA_ROOT" ]] ||
            die "Docker is already running with data-root '${current_root}'. Migrate it deliberately before changing the data-root."
    elif [[ "$configured_root" != "$DOCKER_DATA_ROOT" ]] &&
         [[ -d /var/lib/docker ]] &&
         find /var/lib/docker -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
        die "/var/lib/docker contains data but Docker is not running and is not configured for ${DOCKER_DATA_ROOT}. Inspect/migrate it before continuing."
    fi

    log "Preflight OK: Debian ${VERSION_ID} (${VERSION_CODENAME}), ${source} mounted at ${DATA_ROOT}."
    log "Available space: $((available_kb / 1024)) MiB."
}

install_utility_packages() {
    local packages=(
        apparmor
        acl
        iproute2
        iptables
        nftables
        sysstat
        iotop
        ncdu
        tree
        tmux
        smartmontools
        logrotate
        needrestart
        curl
        ca-certificates
        gnupg
        jq
        git
        rsync
        unzip
        zip
        xz-utils
        dnsutils
        netcat-openbsd
        tcpdump
        lsof
        procps
    )

    log "Updating Debian package indexes."
    apt-get update

    log "Installing useful general-purpose Docker host utilities."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
}

configure_docker_repository() {
    log "Configuring Docker's official Debian APT repository."

    install -m 0755 -d /etc/apt/keyrings
    local temp_key
    temp_key="$(mktemp)"
    curl -fsSL https://download.docker.com/linux/debian/gpg -o "$temp_key"
    gpg --dearmor --yes --output "${temp_key}.gpg" "$temp_key"
    install -m 0644 "${temp_key}.gpg" "$DOCKER_KEYRING"
    rm -f "$temp_key" "${temp_key}.gpg"

    local architecture
    architecture="$(dpkg --print-architecture)"

    cat > "${DOCKER_REPO_FILE}.tmp" <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Architectures: ${architecture}
Signed-By: ${DOCKER_KEYRING}
EOF
    chmod 0644 "${DOCKER_REPO_FILE}.tmp"
    mv "${DOCKER_REPO_FILE}.tmp" "$DOCKER_REPO_FILE"

    apt-get update
}

install_docker_packages() {
    local conflicting=(
        docker.io
        docker-compose
        docker-doc
        docker-buildx
        podman-docker
        containerd
        runc
    )
    local installed=()
    local package

    for package in "${conflicting[@]}"; do
        if dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed; then
            installed+=("$package")
        fi
    done

    if ((${#installed[@]} > 0)); then
        printf 'Conflicting packages detected: %s\n' "${installed[*]}" | tee -a "$LOG_FILE"
        die "Remove conflicting packages deliberately, review their impact, then rerun. Nothing was automatically removed."
    fi

    log "Installing Docker Engine, CLI, containerd, Buildx, and Compose V2."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
}

configure_docker_group() {
    log "Ensuring ${ADMIN_USER} can use Docker."
    getent group docker >/dev/null 2>&1 || groupadd --system docker
    usermod -aG docker "$ADMIN_USER"
}

configure_docker_daemon() {
    log "Configuring Docker storage and container log rotation."

    install -d -o root -g root -m 0711 "$DOCKER_DATA_ROOT"
    install -d -o root -g root -m 0755 /etc/docker

    local temp_config
    temp_config="$(mktemp /etc/docker/daemon.json.XXXXXX)"

    if [[ -f "$DOCKER_CONFIG" ]]; then
        # Preserve unrelated settings and merge the settings managed by this script.
        jq \
            --arg root "$DOCKER_DATA_ROOT" \
            '. + {
                "data-root": $root,
                "log-driver": "local",
                "live-restore": true
            } | .["log-opts"] = ((.["log-opts"] // {}) + {
                "max-size": "10m",
                "max-file": "3"
            })' \
            "$DOCKER_CONFIG" > "$temp_config"
    else
        cat > "$temp_config" <<EOF
{
  "data-root": "${DOCKER_DATA_ROOT}",
  "log-driver": "local",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true
}
EOF
    fi

    jq -e 'type == "object"' "$temp_config" >/dev/null
    chmod 0644 "$temp_config"

    if [[ -f "$DOCKER_CONFIG" ]] && ! cmp -s "$temp_config" "$DOCKER_CONFIG"; then
        cp -a "$DOCKER_CONFIG" "${DOCKER_CONFIG}.backup.$(date +%Y%m%d%H%M%S)"
    fi
    mv "$temp_config" "$DOCKER_CONFIG"

    chown root:root "$DOCKER_DATA_ROOT"
    chmod 0711 "$DOCKER_DATA_ROOT"
}

enable_and_validate_docker() {
    log "Enabling and starting Docker services."
    systemctl enable --now containerd
    systemctl enable --now docker

    systemctl is-active --quiet containerd || die "containerd is not active."
    systemctl is-active --quiet docker || die "Docker is not active."

    local actual_root
    actual_root="$(docker info --format '{{.DockerRootDir}}')"
    [[ "$actual_root" == "$DOCKER_DATA_ROOT" ]] ||
        die "Docker reports data-root '${actual_root}', expected '${DOCKER_DATA_ROOT}'."

    log "Running Docker hello-world smoke test (this downloads a small test image)."
    docker run --rm hello-world
    log "Docker Engine smoke test passed."
}

print_summary() {
    printf '\n'
    printf '%s\n' "========== DOCKER SERVER INSTALLATION SUMMARY =========="
    printf 'OS:                %s\n' "$( . /etc/os-release; echo "${PRETTY_NAME:-Debian}")"
    printf 'Docker Engine:     %s\n' "$(docker --version)"
    printf 'Docker Compose:    %s\n' "$(docker compose version)"
    printf 'Docker Buildx:     %s\n' "$(docker buildx version)"
    printf 'containerd:        %s\n' "$(containerd --version)"
    printf 'Docker data-root:  %s\n' "$(docker info --format '{{.DockerRootDir}}')"
    printf 'Storage mount:     %s\n' "$(findmnt -n -o SOURCE,FSTYPE,OPTIONS --target "$DATA_ROOT")"
    printf 'Docker service:    %s\n' "$(systemctl is-active docker)"
    printf 'containerd:        %s\n' "$(systemctl is-active containerd)"
    printf 'Docker group:      %s\n' "$(getent group docker)"
    printf 'Log config:        local (10m max, 3 files)\n'
    printf 'Daemon config:     %s\n' "$DOCKER_CONFIG"
    printf 'Execution log:     %s\n' "$LOG_FILE"
    printf '%s\n' "========================================================="
    printf '\n'
    log "Installation completed successfully."
    log "Log out and reconnect for ${ADMIN_USER}'s Docker group membership to take effect."
    log "Host Node.js, OpenClaw, LiteLLM, and application stacks were not installed."
}

main() {
    require_root
    touch "$LOG_FILE"
    chmod 0640 "$LOG_FILE"

    preflight
    install_utility_packages
    configure_docker_repository
    install_docker_packages
    configure_docker_group
    configure_docker_daemon
    enable_and_validate_docker
    print_summary
}

main "$@"
