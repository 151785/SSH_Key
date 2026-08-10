#!/usr/bin/env bash
#=============================================================
# SSH Key Installer - Enhanced Edition
# Based on: https://github.com/P3TERX/SSH_Key_Installer (v2.7)
# Modifications: Fixed restart compatibility, added backup/rollback,
#                config validation, duplicate prevention, and more.
# Version: 2.8
#=============================================================

VERSION="2.8"
RED_FONT_PREFIX="\033[31m"
LIGHT_GREEN_FONT_PREFIX="\033[1;32m"
FONT_COLOR_SUFFIX="\033[0m"
INFO="[${LIGHT_GREEN_FONT_PREFIX}INFO${FONT_COLOR_SUFFIX}]"
ERROR="[${RED_FONT_PREFIX}ERROR${FONT_COLOR_SUFFIX}]"
[ $EUID != 0 ] && SUDO=sudo

USAGE() {
    cat <<EOF
SSH Key Installer $VERSION

Usage:
  bash key.sh [options...] <arg>

Options:
  -o    Overwrite mode (top-level)
  -g    Get public key from GitHub, arg = GitHub ID
  -u    Get public key from URL, arg = URL
  -f    Get public key from local file, arg = file path
  -p    Change SSH port, arg = port number
  -d    Disable password login
EOF
}

if [ $# -eq 0 ]; then
    USAGE
    exit 1
fi

# ---------- 获取公钥 ----------
get_github_key() {
    if [ -z "${KEY_ID}" ]; then
        read -e -p "Please enter the GitHub account: " KEY_ID
        [ -z "${KEY_ID}" ] && echo -e "${ERROR} Invalid input." && exit 1
    fi
    echo -e "${INFO} GitHub account: ${KEY_ID}"
    echo -e "${INFO} Fetching keys from GitHub..."
    PUB_KEY=$(curl -fsSL "https://github.com/${KEY_ID}.keys")
    if [ "${PUB_KEY}" = "Not Found" ] || [ -z "${PUB_KEY}" ]; then
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
    [ -z "${PUB_KEY}" ] && echo -e "${ERROR} Failed to fetch key or key is empty." && exit 1
}

get_local_key() {   # 修正拼写
    if [ -z "${KEY_PATH}" ]; then
        read -e -p "Please enter the local file path: " KEY_PATH
        [ -z "${KEY_PATH}" ] && echo -e "${ERROR} Invalid input." && exit 1
    fi
    echo -e "${INFO} Reading key from ${KEY_PATH}..."
    [ ! -f "${KEY_PATH}" ] && echo -e "${ERROR} File not found." && exit 1
    PUB_KEY=$(cat "${KEY_PATH}" 2>/dev/null)
    [ -z "${PUB_KEY}" ] && echo -e "${ERROR} File is empty or unreadable." && exit 1
}

# ---------- 安装公钥 ----------
install_key() {
    [ -z "${PUB_KEY}" ] && echo -e "${ERROR} No public key to install." && exit 1

    SSH_DIR="${HOME}/.ssh"
    AUTH_KEYS="${SSH_DIR}/authorized_keys"

    mkdir -p "${SSH_DIR}"
    if [ ! -f "${AUTH_KEYS}" ]; then
        echo -e "${INFO} Creating ${AUTH_KEYS}..."
        touch "${AUTH_KEYS}"
    fi

    # 检查是否已存在（避免重复）
    if grep -Fxq "${PUB_KEY}" "${AUTH_KEYS}" 2>/dev/null && [ "${OVERWRITE}" != "1" ]; then
        echo -e "${INFO} Key already exists, skipping."
        return 0
    fi

    if [ "${OVERWRITE}" = "1" ]; then
        echo -e "${INFO} Overwriting authorized_keys..."
        echo "${PUB_KEY}" > "${AUTH_KEYS}"
    else
        echo -e "${INFO} Appending SSH key..."
        echo "" >> "${AUTH_KEYS}"
        echo "${PUB_KEY}" >> "${AUTH_KEYS}"
    fi

    chmod 700 "${SSH_DIR}"
    chmod 600 "${AUTH_KEYS}"

    if grep -Fxq "${PUB_KEY}" "${AUTH_KEYS}" 2>/dev/null; then
        echo -e "${INFO} SSH key installed successfully!"
    else
        echo -e "${ERROR} SSH key installation failed!"
        exit 1
    fi
}

# ---------- 修改端口（带备份和语法检查） ----------
change_port() {
    local port="${SSH_PORT}"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${ERROR} Invalid port number."
        exit 1
    fi

    if [ "$(uname -o)" = "Android" ]; then
        SSHD_CONFIG="$PREFIX/etc/ssh/sshd_config"
    else
        SSHD_CONFIG="/etc/ssh/sshd_config"
    fi

    [ ! -f "${SSHD_CONFIG}" ] && echo -e "${ERROR} ${SSHD_CONFIG} not found." && exit 1

    # 备份
    BACKUP="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    $SUDO cp -a "${SSHD_CONFIG}" "${BACKUP}"
    echo -e "${INFO} Backup saved to ${BACKUP}"

    # 修改端口（处理空格和注释）
    if grep -qE '^[[:space:]]*Port ' "${SSHD_CONFIG}"; then
        $SUDO sed -i "s/^[[:space:]]*Port .*/Port ${port}/" "${SSHD_CONFIG}"
    else
        echo "Port ${port}" | $SUDO tee -a "${SSHD_CONFIG}" >/dev/null
    fi

    # 验证语法（非Android环境）
    if [ "$(uname -o)" != "Android" ]; then
        if ! $SUDO sshd -t 2>/dev/null; then
            echo -e "${ERROR} Invalid SSH configuration. Restoring backup..."
            $SUDO cp -a "${BACKUP}" "${SSHD_CONFIG}"
            exit 1
        fi
    fi

    grep -qE "^[[:space:]]*Port ${port}[[:space:]]*$" "${SSHD_CONFIG}" && {
        echo -e "${INFO} SSH port changed to ${port}."
        RESTART_SSHD=1
    } || {
        echo -e "${ERROR} Failed to change port. Restoring backup..."
        $SUDO cp -a "${BACKUP}" "${SSHD_CONFIG}"
        exit 1
    }
}

# ---------- 禁用密码登录（带备份和语法检查） ----------
disable_password() {
    if [ "$(uname -o)" = "Android" ]; then
        SSHD_CONFIG="$PREFIX/etc/ssh/sshd_config"
    else
        SSHD_CONFIG="/etc/ssh/sshd_config"
    fi

    [ ! -f "${SSHD_CONFIG}" ] && echo -e "${ERROR} ${SSHD_CONFIG} not found." && exit 1

    BACKUP="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    $SUDO cp -a "${SSHD_CONFIG}" "${BACKUP}"
    echo -e "${INFO} Backup saved to ${BACKUP}"

    if grep -qE '^[[:space:]]*PasswordAuthentication ' "${SSHD_CONFIG}"; then
        $SUDO sed -i "s/^[[:space:]]*PasswordAuthentication .*/PasswordAuthentication no/" "${SSHD_CONFIG}"
    else
        echo "PasswordAuthentication no" | $SUDO tee -a "${SSHD_CONFIG}" >/dev/null
    fi

    if [ "$(uname -o)" != "Android" ]; then
        if ! $SUDO sshd -t 2>/dev/null; then
            echo -e "${ERROR} Invalid SSH configuration. Restoring backup..."
            $SUDO cp -a "${BACKUP}" "${SSHD_CONFIG}"
            exit 1
        fi
    fi

    grep -qE '^[[:space:]]*PasswordAuthentication no[[:space:]]*$' "${SSHD_CONFIG}" && {
        echo -e "${INFO} Password authentication disabled."
        RESTART_SSHD=1
    } || {
        echo -e "${ERROR} Failed to disable password login. Restoring backup..."
        $SUDO cp -a "${BACKUP}" "${SSHD_CONFIG}"
        exit 1
    }
}

# ---------- 智能重启 SSH（兼容多种 init 系统） ----------
restart_ssh() {
    # 检测当前运行的 SSH 进程名
    local detected_svc
    detected_svc=$(ps -eo comm= | grep -E 'sshd|opensshd|ssh' | head -n1)
    [ -n "$detected_svc" ] && echo -e "${INFO} Detected SSH process: $detected_svc" || detected_svc="sshd"

    # 构建重启命令列表（去重）
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
        # 去重
        local skip=0
        for t in "${tried[@]}"; do
            [ "$t" = "$cmd" ] && skip=1 && break
        done
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
    echo "  sudo systemctl restart ssh   # Ubuntu/Debian"
    echo "  sudo systemctl restart sshd  # CentOS/RHEL"
    echo "  sudo service ssh restart     # SysV"
    return 1
}

# ---------- 主选项处理 ----------
while getopts "og:u:f:p:d" OPT; do
    case $OPT in
        o) OVERWRITE=1 ;;
        g) KEY_ID="$OPTARG"; get_github_key; install_key ;;
        u) KEY_URL="$OPTARG"; get_url_key; install_key ;;
        f) KEY_PATH="$OPTARG"; get_local_key; install_key ;;
        p) SSH_PORT="$OPTARG"; change_port ;;
        d) disable_password ;;
        ?) USAGE; exit 1 ;;
        :) USAGE; exit 1 ;;
        *) USAGE; exit 1 ;;
    esac
done

# 重启 SSH（如果标记）
if [ "$RESTART_SSHD" = "1" ]; then
    if [ "$(uname -o)" = "Android" ]; then
        echo -e "${INFO} Restart sshd or Termux App to take effect."
    else
        restart_ssh
    fi
fi

exit 0
