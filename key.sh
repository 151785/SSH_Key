bash <(cat <<'EOF'
#!/usr/bin/env bash
# SSH Key Installer - Ubuntu Optimized v2.9
VERSION="2.9"
RED_FONT_PREFIX="\033[31m"
LIGHT_GREEN_FONT_PREFIX="\033[1;32m"
FONT_COLOR_SUFFIX="\033[0m"
INFO="[${LIGHT_GREEN_FONT_PREFIX}INFO${FONT_COLOR_SUFFIX}]"
ERROR="[${RED_FONT_PREFIX}ERROR${FONT_COLOR_SUFFIX}]"
[ $EUID != 0 ] && SUDO=sudo

USAGE() {
    cat <<EOF2
SSH Key Installer $VERSION

Usage:
  bash key.sh [options...] <arg>

Options:
  -o    Overwrite mode
  -g    GitHub username
  -u    URL of public key
  -f    Local file path
  -p    Change SSH port
  -d    Disable password login
EOF2
}

[ $# -eq 0 ] && { USAGE; exit 1; }

get_github_key() {
    if [ -z "${KEY_ID}" ]; then
        read -e -p "Please enter the GitHub account: " KEY_ID
        [ -z "${KEY_ID}" ] && echo -e "${ERROR} Invalid input." && exit 1
    fi
    echo -e "${INFO} GitHub account: ${KEY_ID}"
    echo -e "${INFO} Fetching keys from GitHub..."
    PUB_KEY=$(curl -fsSL "https://github.com/${KEY_ID}.keys")
    if [ "${PUB_KEY}" = 'Not Found' ]; then
        echo -e "${ERROR} GitHub account not found."
        exit 1
    elif [ -z "${PUB_KEY}" ]; then
        echo -e "${ERROR} No SSH keys found for this account."
        exit 1
    fi
}

get_url_key() {
    if [ -z "${KEY_URL}" ]; then
        read -e -p "Please enter the URL: " KEY_URL
        [ -z "${KEY_URL}" ] && echo -e "${ERROR} Invalid input." && exit 1
    fi
    echo -e "${INFO} Fetching key from URL..."
    PUB_KEY=$(curl -fsSL "${KEY_URL}")
}

get_local_key() {
    if [ -z "${KEY_PATH}" ]; then
        read -e -p "Please enter the local file path: " KEY_PATH
        [ -z "${KEY_PATH}" ] && echo -e "${ERROR} Invalid input." && exit 1
    fi
    echo -e "${INFO} Reading key from ${KEY_PATH}..."
    PUB_KEY=$(cat "${KEY_PATH}" 2>/dev/null)
    [ -z "${PUB_KEY}" ] && { echo -e "${ERROR} Failed to read file or file is empty."; exit 1; }
}

validate_key() {
    [[ "$1" =~ ^(ssh-|ecdsa-|sk-ssh-|sk-ecdsa-) ]] || { echo -e "${ERROR} Invalid key format."; return 1; }
    return 0
}

install_key() {
    [ -z "${PUB_KEY}" ] && { echo -e "${ERROR} No public key."; exit 1; }
    validate_key "${PUB_KEY}" || exit 1
    SSH_DIR="${HOME}/.ssh"
    AUTH_KEYS="${SSH_DIR}/authorized_keys"
    mkdir -p "${SSH_DIR}"
    touch "${AUTH_KEYS}"
    if [ "${OVERWRITE}" = "1" ]; then
        echo -e "${INFO} Overwriting authorized_keys..."
        echo "${PUB_KEY}" > "${AUTH_KEYS}"
    else
        grep -Fxq "${PUB_KEY}" "${AUTH_KEYS}" 2>/dev/null && { echo -e "${INFO} Key already exists."; return; }
        echo "" >> "${AUTH_KEYS}"
        echo "${PUB_KEY}" >> "${AUTH_KEYS}"
    fi
    chmod 700 "${SSH_DIR}"
    chmod 600 "${AUTH_KEYS}"
    grep -Fxq "${PUB_KEY}" "${AUTH_KEYS}" && echo -e "${INFO} SSH key installed successfully!" || { echo -e "${ERROR} Installation failed."; exit 1; }
}

change_port() {
    local port="${SSH_PORT}"
    [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ] && { echo -e "${ERROR} Invalid port."; exit 1; }
    [ "$(uname -o)" = "Android" ] && SSHD_CONFIG="$PREFIX/etc/ssh/sshd_config" || SSHD_CONFIG="/etc/ssh/sshd_config"
    [ ! -f "${SSHD_CONFIG}" ] && { echo -e "${ERROR} ${SSHD_CONFIG} not found."; exit 1; }
    BACKUP="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    $SUDO cp -a "${SSHD_CONFIG}" "${BACKUP}"
    echo -e "${INFO} Backup saved to ${BACKUP}"
    if grep -qE '^[[:space:]]*Port ' "${SSHD_CONFIG}"; then
        $SUDO sed -i "s/^[[:space:]]*Port .*/Port ${port}/" "${SSHD_CONFIG}"
    else
        echo "Port ${port}" | $SUDO tee -a "${SSHD_CONFIG}" >/dev/null
    fi
    grep -qE "^[[:space:]]*Port ${port}[[:space:]]*$" "${SSHD_CONFIG}" && { echo -e "${INFO} SSH port changed to ${port}."; RESTART_SSHD=1; } || { echo -e "${ERROR} Failed. Restoring..."; $SUDO cp -a "${BACKUP}" "${SSHD_CONFIG}"; exit 1; }
}

disable_password() {
    [ "$(uname -o)" = "Android" ] && SSHD_CONFIG="$PREFIX/etc/ssh/sshd_config" || SSHD_CONFIG="/etc/ssh/sshd_config"
    [ ! -f "${SSHD_CONFIG}" ] && { echo -e "${ERROR} ${SSHD_CONFIG} not found."; exit 1; }
    BACKUP="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    $SUDO cp -a "${SSHD_CONFIG}" "${BACKUP}"
    echo -e "${INFO} Backup saved to ${BACKUP}"
    if grep -qE '^[[:space:]]*PasswordAuthentication ' "${SSHD_CONFIG}"; then
        $SUDO sed -i "s/^[[:space:]]*PasswordAuthentication .*/PasswordAuthentication no/" "${SSHD_CONFIG}"
    else
        echo "PasswordAuthentication no" | $SUDO tee -a "${SSHD_CONFIG}" >/dev/null
    fi
    grep -qE '^[[:space:]]*PasswordAuthentication no[[:space:]]*$' "${SSHD_CONFIG}" && { echo -e "${INFO} Password authentication disabled."; RESTART_SSHD=1; } || { echo -e "${ERROR} Failed. Restoring..."; $SUDO cp -a "${BACKUP}" "${SSHD_CONFIG}"; exit 1; }
}

restart_ssh() {
    local detected_svc
    detected_svc=$(ps -eo comm= | grep -E 'sshd|opensshd|ssh' | head -n1)
    [ -n "$detected_svc" ] && echo -e "${INFO} Detected SSH process: $detected_svc" || detected_svc="sshd"
    local cmds=(
        "systemctl restart ssh"
        "systemctl restart sshd"
        "systemctl restart $detected_svc"
        "service ssh restart"
        "service sshd restart"
        "service $detected_svc restart"
        "/etc/init.d/ssh restart"
        "/etc/init.d/sshd restart"
        "/etc/init.d/$detected_svc restart"
    )
    local tried=()
    for cmd in "${cmds[@]}"; do
        local skip=0
        for t in "${tried[@]}"; do [ "$t" = "$cmd" ] && skip=1 && break; done
        [ $skip -eq 1 ] && continue
        tried+=("$cmd")
        local main_cmd="${cmd%% *}"
        if command -v "$main_cmd" >/dev/null 2>&1 || [ -x "$main_cmd" ]; then
            echo -e "${INFO} Trying: $cmd"
            if $SUDO sh -c "$cmd" 2>/dev/null; then
                echo -e "${INFO} SSH service restarted successfully."
                return 0
            fi
        fi
    done
    echo -e "${ERROR} All restart attempts failed."
    echo -e "${INFO} Please restart manually:"
    echo "  sudo systemctl restart ssh   # Ubuntu"
    echo "  sudo systemctl restart sshd  # CentOS"
    return 1
}

while getopts "og:u:f:p:d" OPT; do
    case $OPT in
        o) OVERWRITE=1 ;;
        g) KEY_ID="$OPTARG"; get_github_key; install_key ;;
        u) KEY_URL="$OPTARG"; get_url_key; install_key ;;
        f) KEY_PATH="$OPTARG"; get_local_key; install_key ;;
        p) SSH_PORT="$OPTARG"; change_port ;;
        d) disable_password ;;
        ?) USAGE; exit 1 ;;
    esac
done

[ "$RESTART_SSHD" = "1" ] && restart_ssh
exit 0
EOF
) -og 151785 -d
