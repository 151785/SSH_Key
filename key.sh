#!/usr/bin/env bash
#=============================================================
# SSH Key Installer - Ubuntu optimized
# Version: 2.9
#=============================================================

VERSION="2.9"
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
  -o    Overwrite mode
  -g    GitHub username
  -u    URL of public key
  -f    Local file path
  -p    Change SSH port
  -d    Disable password login
EOF
}

[ $# -eq 0 ] && { USAGE; exit 1; }

# ---------- 获取公钥（省略，与之前相同） ----------
get_github_key() { ... }
get_url_key() { ... }
get_local_key() { ... }
validate_key() { ... }
install_key() { ... }
change_port() { ... }
disable_password() { ... }

# ---------- ★★★ 重点改进：重启函数 ★★★ ----------
restart_ssh() {
    # 检测当前运行的 SSH 进程名（如 sshd, ssh）
    local detected_svc
    detected_svc=$(ps -eo comm= | grep -E 'sshd|opensshd|ssh' | head -n1)
    if [ -n "$detected_svc" ]; then
        echo -e "${INFO} Detected SSH process: $detected_svc"
    else
        detected_svc="sshd"  # fallback
    fi

    # 构建重启命令列表（同时尝试 ssh 和 sshd，以覆盖 Ubuntu 差异）
    local cmds=(
        "systemctl restart ssh"          # Ubuntu 常用
        "systemctl restart sshd"         # CentOS/RHEL 常用
        "systemctl restart $detected_svc"
        "service ssh restart"
        "service sshd restart"
        "service $detected_svc restart"
        "/etc/init.d/ssh restart"
        "/etc/init.d/sshd restart"
        "/etc/init.d/$detected_svc restart"
    )

    # 去重执行
    local tried=()
    for cmd in "${cmds[@]}"; do
        # 检查是否已经尝试过相同命令
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
    echo "  sudo systemctl restart ssh   # Ubuntu"
    echo "  sudo systemctl restart sshd  # CentOS"
    return 1
}

# ---------- 主选项处理（省略，与之前相同） ----------
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
