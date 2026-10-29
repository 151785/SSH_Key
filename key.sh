#!/usr/bin/env bash
#=============================================================
# SSH Key Installer - Universal Edition (Fixed)
# Compatible: Ubuntu 20.04/22.04/24.04/26.04
#             Debian 10/11/12/13
# Version: 3.1
#=============================================================

VERSION="3.1"
RED='\033[31m'; GREEN='\033[1;32m'; NC='\033[0m'
INFO="[${GREEN}INFO${NC}]"; ERROR="[${RED}ERROR${NC}]"

# ---------- 权限检测 ----------
if [ "$EUID" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then SUDO=sudo
    else echo -e "${ERROR} sudo not found and not root."; exit 1; fi
fi

USAGE() {
    cat <<EOF
SSH Key Installer $VERSION
Usage: bash key.sh [options...] <arg>
  -o    Overwrite authorized_keys
  -g    GitHub ID
  -u    URL
  -f    Local file path
  -p    New SSH port
  -d    Disable password login
  -h    Help
EOF
}

# ---------- 检测 socket 是否活跃 ----------
ssh_socket_active() {
    command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet ssh.socket 2>/dev/null
}

# ---------- 获取公钥 ----------
get_github_key() {
    [ -z "${KEY_ID}" ] && read -e -p "GitHub account: " KEY_ID
    [ -z "${KEY_ID}" ] && echo -e "${ERROR} Invalid." && exit 1
    PUB_KEY=$(curl -fsSL "https://github.com/${KEY_ID}.keys")
    [ -z "${PUB_KEY}" ] || [ "${PUB_KEY}" = "Not Found" ] && echo -e "${ERROR} No keys." && exit 1
}
get_url_key() {
    [ -z "${KEY_URL}" ] && read -e -p "URL: " KEY_URL
    [ -z "${KEY_URL}" ] && echo -e "${ERROR} Invalid." && exit 1
    PUB_KEY=$(curl -fsSL "${KEY_URL}")
    [ -z "${PUB_KEY}" ] && echo -e "${ERROR} Fetch failed." && exit 1
}
get_local_key() {
    [ -z "${KEY_PATH}" ] && read -e -p "File path: " KEY_PATH
    [ ! -f "${KEY_PATH}" ] && echo -e "${ERROR} Not found." && exit 1
    PUB_KEY=$(cat "${KEY_PATH}" 2>/dev/null)
    [ -z "${PUB_KEY}" ] && echo -e "${ERROR} Empty." && exit 1
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
        grep -Fxq "${key}" "${AUTH}" 2>/dev/null || { printf '%s\n' "${key}" >> "${AUTH}"; added=$((added+1)); }
    done <<< "${PUB_KEY}"
    chmod 600 "${AUTH}"
    echo -e "${INFO} Installed ${added} key(s)."
}

# ---------- 写入配置（使用 01- 前缀确保优先级） ----------
ssh_config_set() {
    local key="$1" value="$2"
    local dropin_dir="/etc/ssh/sshd_config.d"
    local dropin_file="${dropin_dir}/01-ssh-key-installer.conf"
    local SSHD_CONFIG="/etc/ssh/sshd_config"

    if [ -d "${dropin_dir}" ]; then
        # 01- 前缀确保先于 50-cloud-init / 60-cloudimg 被读取
        if grep -qE "^[[:space:]]*${key}[[:space:]]" "${dropin_file}" 2>/dev/null; then
            $SUDO sed -i "s|^[[:space:]]*${key} .*|${key} ${value}|" "${dropin_file}"
        else
            echo "${key} ${value}" | $SUDO tee -a "${dropin_file}" >/dev/null
        fi
        echo -e "${INFO} Wrote ${key} ${value} to ${dropin_file}"
    else
        # Debian 10/11 等无 drop-in 目录
        if grep -qE "^[[:space:]]*${key} " "${SSHD_CONFIG}" 2>/dev/null; then
            $SUDO sed -i "s/^[[:space:]]*${key} .*/${key} ${value}/" "${SSHD_CONFIG}"
        else
            echo "${key} ${value}" | $SUDO tee -a "${SSHD_CONFIG}" >/dev/null
        fi
        echo -e "${INFO} Wrote ${key} ${value} to ${SSHD_CONFIG}"
    fi
}

# ---------- 验证配置（sshd -T 输出合并后的有效配置） ----------
validate_effective() {
    local key="$1" expected="$2"
    local actual
    actual=$($SUDO sshd -T 2>/dev/null | grep -iE "^${key} " | awk '{print $2}')
    if [ "${actual}" = "${expected}" ]; then
        echo -e "${INFO} Effective config verified: ${key} = ${actual}"
        return 0
    else
        echo -e "${ERROR} Effective config mismatch: ${key} = ${actual:-<empty>} (expected ${expected})"
        return 1
    fi
}

# ---------- 备份 ----------
backup_config() {
    local f="/etc/ssh/sshd_config"
    local bak="${f}.bak.$(date +%Y%m%d%H%M%S)"
    $SUDO cp -a "${f}" "${bak}" 2>/dev/null
    echo -e "${INFO} Backup: ${bak}"
}

# ---------- 修改端口（核心适配） ----------
change_port() {
    local port="${SSH_PORT}"
    [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ] && { echo -e "${ERROR} Invalid port."; exit 1; }

    backup_config
    ssh_config_set "Port" "${port}"

    # 语法检查
    if ! $SUDO sshd -t 2>/dev/null; then
        echo -e "${ERROR} Syntax error:"; $SUDO sshd -t 2>&1
        exit 1
    fi

    if ssh_socket_active; then
        echo -e "${INFO} ssh.socket active, writing override..."
        local od="/etc/systemd/system/ssh.socket.d"
        $SUDO mkdir -p "${od}"
        $SUDO tee "${od}/override.conf" >/dev/null <<EOF
[Socket]
ListenStream=
ListenStream=0.0.0.0:${port}
ListenStream=[::]:${port}
EOF
        $SUDO systemctl daemon-reload
        $SUDO systemctl restart ssh.socket
        sleep 1
        # 验证监听
        if ss -tln 2>/dev/null | grep -q ":${port} "; then
            echo -e "${INFO} Port ${port} is listening."
        else
            echo -e "${ERROR} Port ${port} not listening!"; exit 1
        fi
    else
        echo -e "${INFO} Restarting ssh.service..."
        $SUDO systemctl restart ssh.service 2>/dev/null || $SUDO systemctl restart ssh 2>/dev/null || $SUDO service ssh restart
        sleep 1
        ss -tln 2>/dev/null | grep -q ":${port} " && echo -e "${INFO} Port ${port} listening." || { echo -e "${ERROR} Port not listening."; exit 1; }
    fi
    echo -e "${INFO} SSH port changed to ${port}."
    RESTART_SSHD=1
}

# ---------- 禁用密码登录（带有效配置验证） ----------
disable_password() {
    backup_config
    ssh_config_set "PasswordAuthentication" "no"

    # 同时关闭 keyboard-interactive 以防绕过[citation:5]
    ssh_config_set "KbdInteractiveAuthentication" "no"

    # 语法检查
    if ! $SUDO sshd -t 2>/dev/null; then
        echo -e "${ERROR} Syntax error:"; $SUDO sshd -t 2>&1; exit 1
    fi

    # 关键：验证合并后的有效配置
    if ! validate_effective "passwordauthentication" "no"; then
        echo -e "${ERROR} Configuration was written but NOT effective."
        echo -e "${ERROR} A higher-priority drop-in (e.g. 50-cloud-init.conf) is overriding it."
        echo -e "${INFO} Check files in /etc/ssh/sshd_config.d/ and remove conflicting ones."
        exit 1
    fi

    echo -e "${INFO} Password authentication disabled (verified)."
    RESTART_SSHD=1
}

# ---------- 自动重启 SSH ----------
restart_ssh() {
    if ssh_socket_active; then
        echo -e "${INFO} Reloading daemon and restarting ssh.socket..."
        $SUDO systemctl daemon-reload
        $SUDO systemctl restart ssh.socket
        sleep 1
        if systemctl is-active --quiet ssh.socket; then
            echo -e "${INFO} ssh.socket restarted successfully."
            return 0
        fi
    else
        echo -e "${INFO} Restarting ssh.service..."
        $SUDO systemctl restart ssh.service 2>/dev/null || $SUDO systemctl restart ssh 2>/dev/null || $SUDO service ssh restart
        sleep 1
        if $SUDO systemctl is-active --quiet ssh.service 2>/dev/null || $SUDO systemctl is-active --quiet ssh 2>/dev/null; then
            echo -e "${INFO} SSH service restarted."
            return 0
        fi
    fi
    echo -e "${ERROR} Restart verification failed."
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
    restart_ssh || { echo -e "${ERROR} Auto-restart failed. Manual restart required."; exit 1; }
    echo -e "${INFO} All done."
fi
exit 0
