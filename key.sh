#!/usr/bin/env bash
#=============================================================
# SSH Key Installer - Enhanced Edition
# Version: 2.8 (with auto backup, rollback, intelligent service detection)
# Original Author: P3TERX
# Modified: Added robustness improvements
#=============================================================

VERSION="2.8"
RED_FONT_PREFIX="\033[31m"
LIGHT_GREEN_FONT_PREFIX="\033[1;32m"
FONT_COLOR_SUFFIX="\033[0m"
INFO="[${LIGHT_GREEN_FONT_PREFIX}INFO${FONT_COLOR_SUFFIX}]"
ERROR="[${RED_FONT_PREFIX}ERROR${FONT_COLOR_SUFFIX}]"
[ $EUID != 0 ] && SUDO=sudo

# ---------- 函数：显示帮助 ----------
USAGE() {
    cat <<EOF
SSH Key Installer $VERSION

Usage:
  bash <(curl -fsSL git.io/key.sh) [options...] <arg>

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

get_local_key() {   # 修正拼写
    if [ -z "${KEY_PATH}" ]; then
        read -e -p "Please enter the local file path: " KEY_PATH
        [ -z "${KEY_PATH}" ] && echo -e "${ERROR} Invalid input." && exit 1
    fi
    echo -e "${INFO} Reading key from ${KEY_PATH}..."
    PUB_KEY=$(cat "${KEY_PATH}" 2>/dev/null)
    if [ -z "${PUB_KEY}" ]; then
        echo -e "${ERROR} Failed to read file or file is empty."
        exit 1
    fi
}

# ---------- 公钥格式校验 ----------
validate_key() {
    local key="$1"
    # 只检查是否为常见公钥格式开头
    if [[ ! "$key" =~ ^(ssh-|ecdsa-|sk-ssh-|sk-ecdsa-) ]]; then
        echo -e "${ERROR} Invalid public key format. Must start with 'ssh-', 'ecdsa-', etc."
        return 1
    fi
    return 0
}

# ---------- 安装公钥 ----------
install_key() {
    if [ -z "${PUB_KEY}" ]; then
        echo -e "${ERROR} No public key to install."
        exit 1
    fi
    # 校验
    if ! validate_key "${PUB_KEY}"; then
        exit 1
    fi

    SSH_DIR="${HOME}/.ssh"
    AUTH_KEYS="${SSH_DIR}/authorized_keys"

    mkdir -p "${SSH_DIR}"
    if [ ! -f "${AUTH_KEYS}" ]; then
        echo -e "${INFO} Creating ${AUTH_KEYS}..."
        touch "${AUTH_KEYS}"
        chmod 600 "${AUTH_KEYS}"
    fi

    if [ "${OVERWRITE}" = "1" ]; then
        echo -e "${INFO} Overwriting SSH authorized_keys..."
        echo "${PUB_KEY}" > "${AUTH_KEYS}"
    else
        echo -e "${INFO} Appending SSH key..."
        # 避免重复添加（简单检查）
        if grep -Fxq "${PUB_KEY}" "${AUTH_KEYS}" 2>/dev/null; then
            echo -e "${INFO} Key already exists, skipping."
        else
            echo "" >> "${AUTH_KEYS}"
            echo "${PUB_KEY}" >> "${AUTH_KEYS}"
        fi
    fi

    chmod 700 "${SSH_DIR}"
    chmod 600 "${AUTH_KEYS}"

    # 验证是否成功写入
    if grep -Fxq "${PUB_KEY}" "${AUTH_KEYS}" 2>/dev/null; then
        echo -e "${INFO} SSH key installed successfully!"
    else
        echo -e "${ERROR} Failed to install SSH key."
        exit 1
    fi
}

# ---------- 修改端口（带备份和回滚） ----------
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

    if [ ! -f "${SSHD_CONFIG}" ]; then
        echo -e "${ERROR} ${SSHD_CONFIG} not found."
        exit 1
    fi

    # 备份
    BACKUP="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    $SUDO cp -a "${SSHD_CONFIG}" "${BACKUP}"
    echo -e "${INFO} Backup saved to ${BACKUP}"

    # 修改端口
    if grep -qE '^[[:space:]]*Port ' "${SSHD_CONFIG}"; then
        $SUDO sed -i "s/^[[:space:]]*Port .*/Port ${port}/" "${SSHD_CONFIG}"
    else
        echo "Port ${port}" | $SUDO tee -a "${SSHD_CONFIG}" >/dev/null
    fi

    # 验证修改
    if grep -qE "^[[:space:]]*Port ${port}[[:space:]]*$" "${SSHD_CONFIG}"; then
        echo -e "${INFO} SSH port changed to ${port}."
        RESTART_SSHD=1
    else
        echo -e "${ERROR} Failed to change port. Restoring backup..."
        $SUDO cp -a "${BACKUP}" "${SSHD_CONFIG}"
        exit 1
    fi
}

# ---------- 禁用密码登录（带备份） ----------
disable_password() {
    if [ "$(uname -o)" = "Android" ]; then
        SSHD_CONFIG="$PREFIX/etc/ssh/sshd_config"
    else
        SSHD_CONFIG="/etc/ssh/sshd_config"
    fi

    if [ ! -f "${SSHD_CONFIG}" ]; then
        echo -e "${ERROR} ${SSHD_CONFIG} not found."
        exit 1
    fi

    BACKUP="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    $SUDO cp -a "${SSHD_CONFIG}" "${BACKUP}"
    echo -e "${INFO} Backup saved to ${BACKUP}"

    if grep -qE '^[[:space:]]*PasswordAuthentication ' "${SSHD_CONFIG}"; then
        $SUDO sed -i "s/^[[:space:]]*PasswordAuthentication .*/PasswordAuthentication no/" "${SSHD_CONFIG}"
    else
        echo "PasswordAuthentication no" | $SUDO tee -a "${SSHD_CONFIG}" >/dev/null
    fi

    if grep -qE '^[[:space:]]*PasswordAuthentication no[[:space:]]*$' "${SSHD_CONFIG}"; then
        echo -e "${INFO} Password authentication disabled."
        RESTART_SSHD=1
    else
        echo -e "${ERROR} Failed to disable password login. Restoring backup..."
        $SUDO cp -a "${BACKUP}" "${SSHD_CONFIG}"
        exit 1
    fi
}

# ---------- 智能检测SSH服务名 ----------
detect_ssh_service() {
    # 通过ps查找实际运行的sshd进程
    local pname
    pname=$(ps -eo comm= | grep -E 'sshd|opensshd|ssh' | head -n1)
    if [ -n "$pname" ]; then
        echo "$pname"
        return 0
    fi
    # 备用：检查常见服务名
    for svc in sshd ssh opensshd; do
        if systemctl list-unit-files | grep -q "^${svc}\.service" 2>/dev/null; then
            echo "$svc"
            return 0
        fi
    done
    # 默认返回sshd
    echo "sshd"
}

# ---------- 通用重启函数 ----------
restart_ssh() {
    local svc
    svc=$(detect_ssh_service)
    echo -e "${INFO} Detected SSH service: ${svc}"

    local restart_cmds=(
        "systemctl restart ${svc}"
        "systemctl restart sshd"
        "systemctl restart ssh"
        "service ${svc} restart"
        "service sshd restart"
        "service ssh restart"
        "/etc/init.d/${svc} restart"
        "/etc/init.d/sshd restart"
        "/etc/init.d/ssh restart"
    )

    # 去重，保留唯一命令
    local unique_cmds=()
    for cmd in "${restart_cmds[@]}"; do
        local found=0
        for used in "${unique_cmds[@]}"; do
            if [ "$used" = "$cmd" ]; then
                found=1
                break
            fi
        done
        if [ $found -eq 0 ]; then
            unique_cmds+=("$cmd")
        fi
    done

    for cmd in "${unique_cmds[@]}"; do
        # 检查命令是否存在（粗略检查第一个单词）
        local main_cmd="${cmd%% *}"
        if command -v "$main_cmd" >/dev/null 2>&1 || [ -x "$main_cmd" ]; then
            echo -e "${INFO} Trying: $cmd"
            if $SUDO sh -c "$cmd" 2>/dev/null; then
                echo -e "${INFO} SSH service restarted successfully."
                return 0
            fi
        fi
    done

    echo -e "${ERROR} Failed to restart SSH automatically."
    echo -e "${INFO} Please restart SSH manually with one of:"
    echo "  systemctl restart sshd"
    echo "  service sshd restart"
    echo "  /etc/init.d/sshd restart"
    return 1
}

# ---------- 主处理 ----------
while getopts "og:u:f:p:d" OPT; do
    case $OPT in
        o)
            OVERWRITE=1
            ;;
        g)
            KEY_ID="$OPTARG"
            get_github_key
            install_key
            ;;
        u)
            KEY_URL="$OPTARG"
            get_url_key
            install_key
            ;;
        f)
            KEY_PATH="$OPTARG"
            get_local_key
            install_key
            ;;
        p)
            SSH_PORT="$OPTARG"
            change_port
            ;;
        d)
            disable_password
            ;;
        ?)
            USAGE
            exit 1
            ;;
        :)
            USAGE
            exit 1
            ;;
        *)
            USAGE
            exit 1
            ;;
    esac
done

# 如果需要重启SSH
if [ "$RESTART_SSHD" = "1" ]; then
    if [ "$(uname -o)" = "Android" ]; then
        echo -e "${INFO} Please restart Termux or SSH service manually."
    else
        restart_ssh
    fi
fi

exit 0
