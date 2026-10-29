#!/usr/bin/env bash
#=============================================================
# SSH Key Installer - Universal Edition
# Compatible: Ubuntu 20.04/22.04/24.04/26.04
#             Debian 10/11/12/13
# Based on: https://github.com/P3TERX/SSH_Key_Installer (v2.7)
# Version: 3.0
#=============================================================

VERSION="3.0"
RED_FONT_PREFIX="\033[31m"
LIGHT_GREEN_FONT_PREFIX="\033[1;32m"
FONT_COLOR_SUFFIX="\033[0m"
INFO="[${LIGHT_GREEN_FONT_PREFIX}INFO${FONT_COLOR_SUFFIX}]"
ERROR="[${RED_FONT_PREFIX}ERROR${FONT_COLOR_SUFFIX}]"

# ---------- 权限检测 ----------
if [ "$EUID" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO=sudo
    else
        echo -e "${ERROR} sudo not found and not running as root."
        exit 1
    fi
fi

USAGE() {
    cat <<EOF
SSH Key Installer $VERSION

Usage:
  bash key.sh [options...] <arg>

Options:
  -o    Overwrite authorized_keys before install
  -g    Get public key from GitHub, arg = GitHub ID
  -u    Get public key from URL, arg = URL
  -f    Get public key from local file, arg = file path
  -p    Change SSH port, arg = port number
  -d    Disable password login
  -h    Show this help
EOF
}

# ---------- 检测 ssh.socket 是否活跃（关键兼容逻辑） ----------
ssh_socket_active() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet ssh.socket 2>/dev/null
        return $?
    fi
    return 1
}

# ---------- 获取公钥 ----------
get_github_key() {
    [ -z "${KEY_ID}" ] && read -e -p "GitHub account: " KEY_ID
    [ -z "${KEY_ID}" ] && echo -e "${ERROR} Invalid input." && exit 1
    PUB_KEY=$(curl -fsSL "https://github.com/${KEY_ID}.keys")
    if [ "${PUB_KEY}" = "Not Found" ] || [ -z "${PUB_KEY}" ]; then
        echo -e "${ERROR} No SSH keys found."
        exit 1
    fi
}

get_url_key() {
    [ -z "${KEY_URL}" ] && read -e -p "URL: " KEY_URL
    [ -z "${KEY_URL}" ] && echo -e "${ERROR} Invalid input." && exit 1
    PUB_KEY=$(curl -fsSL "${KEY_URL}")
    [ -z "${PUB_KEY}" ] && echo -e "${ERROR} Failed to fetch key." && exit 1
}

get_local_key() {
    [ -z "${KEY_PATH}" ] && read -e -p "File path: " KEY_PATH
    [ -z "${KEY_PATH}" ] && echo -e "${ERROR} Invalid input." && exit 1
    [ ! -f "${KEY_PATH}" ] && echo -e "${ERROR} File not found." && exit 1
    PUB_KEY=$(cat "${KEY_PATH}" 2>/dev/null)
    [ -z "${PUB_KEY}" ] && echo -e "${ERROR} File is empty." && exit 1
}

# ---------- 安装公钥（多行安全） ----------
install_key() {
    [ -z "${PUB_KEY}" ] && echo -e "${ERROR} No key." && exit 1
    local SSH_DIR="${HOME}/.ssh" AUTH="${HOME}/.ssh/authorized_keys"
    mkdir -p "${SSH_DIR}"; touch "${AUTH}"; chmod 700 "${SSH_DIR}"

    [ "${OVERWRITE}" = "1" ] && : > "${AUTH}"

    local added=0
    while IFS= read -r key; do
        [ -z "${key}" ] && continue
        if grep -Fxq "${key}" "${AUTH}" 2>/dev/null; then
            echo -e "${INFO} Key already present."
        else
            printf '%s\n' "${key}" >> "${AUTH}"
            added=$((added + 1))
        fi
    done <<< "${PUB_KEY}"

    chmod 600 "${AUTH}"
    echo -e "${INFO} Installed ${added} key(s)."
}

# ---------- 写入 sshd 配置（优先 drop-in，兼容旧版无目录系统） ----------
ssh_config_set() {
    local key="$1" value="$2"
    local dropin_dir="/etc/ssh/sshd_config.d"
    local dropin_file="${dropin_dir}/99-key-installer.conf"
    local SSHD_CONFIG="/etc/ssh/sshd_config"

    if [ -d "${dropin_dir}" ]; then
        if grep -qE "^[[:space:]]*${key}[[:space:]]" "${dropin_file}" 2>/dev/null; then
            $SUDO sed -i "s|^[[:space:]]*${key} .*|${key} ${value}|" "${dropin_file}"
        else
            echo "${key} ${value}" | $SUDO tee -a "${dropin_file}" >/dev/null
        fi
    else
        # Debian 10/11 等旧系统可能无 drop-in 目录，直接改主配置
        if grep -qE "^[[:space:]]*${key} " "${SSHD_CONFIG}"; then
            $SUDO sed -i "s/^[[:space:]]*${key} .*/${key} ${value}/" "${SSHD_CONFIG}"
        else
            echo "${key} ${value}" | $SUDO tee -a "${SSHD_CONFIG}" >/dev/null
        fi
    fi
}

# ---------- 验证配置 ----------
validate_sshd_config() {
    $SUDO sshd -t >/dev/null 2>&1
}

# ---------- 修改端口（核心适配逻辑） ----------
change_port() {
    local port="${SSH_PORT}"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${ERROR} Invalid port."
        exit 1
    fi

    # 备份
    local BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
    $SUDO cp -a /etc/ssh/sshd_config "${BACKUP}" 2>/dev/null

    # 写入 Port 到 sshd_config（供传统模型使用，也为 socket generator 提供信息）
    ssh_config_set "Port" "${port}"

    if ! validate_sshd_config; then
        echo -e "${ERROR} sshd config test failed."
        $SUDO sshd -t 2>&1
        exit 1
    fi

    # 关键分支：如果 ssh.socket 活跃，必须用 socket override 方式
    if ssh_socket_active; then
        echo -e "${INFO} ssh.socket is active, applying socket override for port ${port}..."
        local override_dir="/etc/systemd/system/ssh.socket.d"
        $SUDO mkdir -p "${override_dir}"
        $SUDO tee "${override_dir}/override.conf" >/dev/null <<EOF
[Socket]
ListenStream=
ListenStream=0.0.0.0:${port}
ListenStream=[::]:${port}
EOF
        $SUDO systemctl daemon-reload
        $SUDO systemctl restart ssh.socket
        echo -e "${INFO} ssh.socket restarted on port ${port}."
    else
        echo -e "${INFO} ssh.socket not active, restarting ssh.service..."
        $SUDO systemctl restart ssh.service 2>/dev/null || $SUDO systemctl restart ssh 2>/dev/null || $SUDO service ssh restart
    fi

    echo -e "${INFO} SSH port changed to ${port}."
    RESTART_SSHD=1
}

# ---------- 禁用密码登录 ----------
disable_password() {
    local BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
    $SUDO cp -a /etc/ssh/sshd_config "${BACKUP}" 2>/dev/null

    ssh_config_set "PasswordAuthentication" "no"

    if ! validate_sshd_config; then
        echo -e "${ERROR} sshd config test failed."
        exit 1
    fi

    echo -e "${INFO} Password authentication disabled."
    RESTART_SSHD=1
}

# ---------- 重启 SSH（智能处理 socket/service 模型） ----------
restart_ssh() {
    if ssh_socket_active; then
        echo -e "${INFO} Restarting ssh.socket..."
        $SUDO systemctl daemon-reload
        $SUDO systemctl restart ssh.socket
        return $?
    fi

    # 传统 service 模型（Ubuntu 20.04/22.04, Debian 10/11/12 等）
    local cmds=(
        "systemctl restart ssh.service"
        "systemctl restart ssh"
        "service ssh restart"
        "/etc/init.d/ssh restart"
    )
    for cmd in "${cmds[@]}"; do
        local main="${cmd%% *}"
        if command -v "$main" >/dev/null 2>&1 || [ -x "$main" ]; then
            $SUDO sh -c "$cmd" 2>/dev/null && return 0
        fi
    done
    return 1
}

# ---------- 选项解析 ----------
ACTION=""
while getopts "og:u:f:p:dh" OPT; do
    case $OPT in
        o) OVERWRITE=1 ;;
        g) ACTION=github; KEY_ID="$OPTARG" ;;
        u) ACTION=url;    KEY_URL="$OPTARG" ;;
        f) ACTION=file;   KEY_PATH="$OPTARG" ;;
        p) ACTION=port;   SSH_PORT="$OPTARG" ;;
        d) ACTION=passwd ;;
        h) USAGE; exit 0 ;;
        *) USAGE; exit 1 ;;
    esac
done

[ -z "$ACTION" ] && USAGE && exit 1

case "$ACTION" in
    github) get_github_key; install_key ;;
    url)    get_url_key;    install_key ;;
    file)   get_local_key;  install_key ;;
    port)   change_port ;;
    passwd) disable_password ;;
esac

if [ "${RESTART_SSHD}" = "1" ]; then
    restart_ssh || { echo -e "${ERROR} Restart failed."; exit 1; }
fi

exit 0
