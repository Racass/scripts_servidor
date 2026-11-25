#!/usr/bin/env bash
#
# prepare-host.sh
# Prepare a Debian 13 host for a future Docker/OpenClaw deployment.
#
# This script DOES NOT install Docker, Node.js, OpenClaw, or modify disks.
# It expects /data to be an ext4 filesystem mounted from /dev/sdb1.
#
set -Eeuo pipefail
umask 027

readonly EXPECTED_DATA_DEVICE="/dev/sdb1"
readonly EXPECTED_DATA_FSTYPE="ext4"
readonly DATA_ROOT="/data"
readonly ADMIN_USER="rafael"
readonly LOG_FILE="/var/log/host-prep.log"

# Ensure administrative binaries are available on minimal Debian installs.
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
    log "Review ${LOG_FILE} before rerunning."
    exit "$exit_code"
}
trap on_error ERR

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this script as root, e.g. sudo bash $0"
}

preflight() {
    log "Starting host preparation preflight."

    [[ -r /etc/os-release ]] || die "/etc/os-release not found."
    # shellcheck disable=SC1091
    source /etc/os-release

    [[ "${ID:-}" == "debian" ]] || die "This script supports Debian only (detected: ${ID:-unknown})."
    [[ "${VERSION_ID:-}" == "13" ]] || die "Expected Debian 13; detected ${VERSION_ID:-unknown}."

    id "$ADMIN_USER" >/dev/null 2>&1 || die "User '${ADMIN_USER}' does not exist."

    command -v findmnt >/dev/null 2>&1 || die "'findmnt' is missing; install util-linux first."
    mountpoint -q "$DATA_ROOT" || die "${DATA_ROOT} is not a mount point. Refusing to create directories on the root filesystem."

    local source fstype
    source="$(findmnt -n -o SOURCE --target "$DATA_ROOT")"
    fstype="$(findmnt -n -o FSTYPE --target "$DATA_ROOT")"

    [[ "$source" == "$EXPECTED_DATA_DEVICE" ]] ||
        die "${DATA_ROOT} is mounted from '${source}', expected '${EXPECTED_DATA_DEVICE}'."
    [[ "$fstype" == "$EXPECTED_DATA_FSTYPE" ]] ||
        die "${DATA_ROOT} uses '${fstype}', expected '${EXPECTED_DATA_FSTYPE}'."

    local available_kb
    available_kb="$(df -Pk "$DATA_ROOT" | awk 'NR==2 {print $4}')"
    [[ "$available_kb" =~ ^[0-9]+$ ]] || die "Could not determine free space on ${DATA_ROOT}."
    (( available_kb >= 1048576 )) || die "Less than 1 GiB is available on ${DATA_ROOT}."

    log "Preflight OK: Debian ${VERSION_ID}; user ${ADMIN_USER}; ${source} (${fstype}) mounted at ${DATA_ROOT}."
    log "Available space on ${DATA_ROOT}: $((available_kb / 1024)) MiB."
}

install_base_packages() {
    local packages=(
        openssh-server
        sudo
        curl
        wget
        git
        ca-certificates
        gnupg
        jq
        unzip
        zip
        xz-utils
        rsync
        vim
        nano
        htop
        btop
        lsof
        dnsutils
        iputils-ping
        netcat-openbsd
        tcpdump
        procps
        build-essential
        pkg-config
        libssl-dev
        libffi-dev
        python3
        python3-pip
        python3-venv
        qemu-guest-agent
        util-linux
        parted
    )

    log "Updating APT package indexes."
    apt-get update

    log "Installing baseline administration and troubleshooting packages."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
}

configure_docker_group() {
    log "Ensuring the docker group exists."
    if ! getent group docker >/dev/null 2>&1; then
        groupadd --system docker
    fi

    log "Adding ${ADMIN_USER} to the docker group."
    usermod -aG docker "$ADMIN_USER"
}

create_data_layout() {
    log "Creating directory structure under ${DATA_ROOT}."

    install -d -o root -g root -m 0711 "${DATA_ROOT}/docker"

    install -d -o "$ADMIN_USER" -g docker -m 2775 \
        "${DATA_ROOT}/stacks" \
        "${DATA_ROOT}/stacks/openclaw" \
        "${DATA_ROOT}/stacks/litellm" \
        "${DATA_ROOT}/stacks/infrastructure" \
        "${DATA_ROOT}/appdata" \
        "${DATA_ROOT}/appdata/openclaw" \
        "${DATA_ROOT}/appdata/litellm" \
        "${DATA_ROOT}/backups" \
        "${DATA_ROOT}/logs" \
        "${DATA_ROOT}/shared"

    # Keep the Docker engine's future data-root owned by root.
    # Application data permissions will be set per container/service later,
    # because container UIDs/GIDs differ between images.
    chown root:root "${DATA_ROOT}/docker"
    chmod 0711 "${DATA_ROOT}/docker"
}

check_services() {
    log "Checking SSH service."
    if systemctl is-active --quiet ssh; then
        log "SSH: active."
    else
        log "WARNING: SSH is not active. No SSH configuration changes were made."
    fi
    if systemctl is-enabled --quiet ssh; then
        log "SSH: enabled at boot."
    else
        log "WARNING: SSH is not enabled at boot. No SSH configuration changes were made."
    fi

    log "Checking QEMU Guest Agent."
    if [[ -e /dev/virtio-ports/org.qemu.guest_agent.0 ]]; then
        if systemctl is-active --quiet qemu-guest-agent; then
            log "QEMU Guest Agent: device present and service active."
        else
            log "WARNING: QEMU Guest Agent device is present but service is not active."
        fi
    else
        log "WARNING: QEMU Guest Agent VirtIO device not found."
    fi

    log "Timezone: $(timedatectl show -p Timezone --value 2>/dev/null || echo 'unknown')"
    log "NTP synchronized: $(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo 'unknown')"
}

print_summary() {
    log "Preparation completed."
    printf '\n'
    printf '%s\n' "========== HOST PREPARATION SUMMARY =========="
    printf 'OS:              %s\n' "$( . /etc/os-release; echo "${PRETTY_NAME:-Debian}")"
    printf 'Admin user:      %s\n' "$ADMIN_USER"
    printf 'Docker group:    %s\n' "$(id -nG "$ADMIN_USER" | tr ' ' ',')"
    printf 'Data mount:      %s\n' "$(findmnt -n -o SOURCE,FSTYPE,OPTIONS --target "$DATA_ROOT")"
    printf 'Data capacity:   %s\n' "$(df -h --output=size,used,avail,pcent "$DATA_ROOT" | tail -n 1 | xargs)"
    printf 'Directory tree:\n'
    find "$DATA_ROOT" -maxdepth 2 -type d -printf '  %M %u:%g %p\n' | sort
    printf 'Log file:        %s\n' "$LOG_FILE"
    printf '%s\n' "=============================================="
    printf '\n'
    log "IMPORTANT: Log out and reconnect for the ${ADMIN_USER} docker-group membership to take effect."
    log "Docker, Docker Compose, Node.js, and OpenClaw were NOT installed."
}

main() {
    require_root
    touch "$LOG_FILE"
    chmod 0640 "$LOG_FILE"

    preflight
    install_base_packages
    configure_docker_group
    create_data_layout
    check_services
    print_summary
}

main "$@"
