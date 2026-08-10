#!/usr/bin/env bash
#=============================================================
# https://github.com/P3TERX/SSH_Key_Installer
# Description: Install SSH keys via GitHub, URL or local files
# Version: 2.7 (Modified for better SSH restart compatibility)
# Author: P3TERX (Modified by user)
# Blog: https://p3terx.com
#=============================================================

VERSION=2.7
RED_FONT_PREFIX="\033[31m"
LIGHT_GREEN_FONT_PREFIX="\033[1;32m"
FONT_COLOR_SUFFIX="\033[0m"
INFO="[${LIGHT_GREEN_FONT_PREFIX}INFO${FONT_COLOR_SUFFIX}]"
ERROR="[${RED_FONT_PREFIX}ERROR${FONT_COLOR_SUFFIX}]"
[ $EUID != 0 ] && SUDO=sudo

USAGE() {
    echo "
SSH Key Installer $VERSION

Usage:
  bash <(curl -fsSL git.io/key.sh) [options...] <arg>

Options:
  -o	Overwrite mode, this option is valid at the top
  -g	Get the public key from GitHub, the arguments is the GitHub ID
  -u	Get the public key from the URL, the arguments is the URL
  -f	Get the public key from the local file, the arguments is the local file path
  -p	Change SSH port, the arguments is port number
  -d	Disable password login"
}

if [ $# -eq 0 ]; then
    USAGE
    exit 1
fi

get_github_key() {
    if [ "${KEY_ID}" == '' ]; then
        read -e -p "Please enter the GitHub account:" KEY_ID
        [ "${KEY_ID}" == '' ] && echo -e "${ERROR} Invalid input." && exit 1
    fi
    echo -e "${INFO} The GitHub account is: ${KEY_ID}"
    echo -e "${INFO} Get key from GitHub..."
    PUB_KEY=$(curl -fsSL https://github.com/${KEY_ID}.keys)
    if [ "${PUB_KEY}" == 'Not Found' ]; then
        echo -e "${ERROR} GitHub account not found."
        exit 1
    elif [ "${PUB_KEY}" == '' ]; then
        echo -e "${ERROR} This account ssh key does not exist."
        exit 1
    fi
}

get_url_key() {
    if [ "${KEY_URL}" == '' ]; then
        read -e -p "Please enter the URL:" KEY_URL
        [ "${KEY_URL}" == '' ] && echo -e "${ERROR} Invalid input." && exit 1
    fi
    echo -e "${INFO} Get key from URL..."
    PUB_KEY=$(curl -fsSL ${KEY_URL})
}

# 修正函数名：loacl -> local
get_local_key() {
    if [ "${KEY_PATH}" == '' ]; then
        read -e -p "Please enter the path:" KEY_PATH
        [ "${KEY_PATH}" == '' ] && echo -e "${ERROR} Invalid input." && exit 1
    fi
    echo -e "${INFO} Get key from ${KEY_PATH}..."
    PUB_KEY=$(cat ${KEY_PATH})
}

install_key() {
    [ "${PUB_KEY}" == '' ] && echo "${ERROR} ssh key does not exist." && exit 1
    if [ ! -f "${HOME}/.ssh/authorized_keys" ]; then
        echo -e "${INFO} '${HOME}/.ssh/authorized_keys' is missing..."
        echo -e "${INFO} Creating ${HOME}/.ssh/authorized_keys..."
        mkdir -p ${HOME}/.ssh/
        touch ${HOME}/.ssh/authorized_keys
        if [ ! -f "${HOME}/.ssh/authorized_keys" ]; then
            echo -e "${ERROR} Failed to create SSH key file."
        else
            echo -e "${INFO} Key file created, proceeding..."
        fi
    fi
    if [ "${OVERWRITE}" == 1 ]; then
        echo -e "${INFO} Overwriting SSH key..."
        echo -e "${PUB_KEY}\n" >${HOME}/.ssh/authorized_keys
    else
        echo -e "${INFO} Adding SSH key..."
        echo -e "\n${PUB_KEY}\n" >>${HOME}/.ssh/authorized_keys
    fi
    chmod 700 ${HOME}/.ssh/
    chmod 600 ${HOME}/.ssh/authorized_keys
    [[ $(grep "${PUB_KEY}" "${HOME}/.ssh/authorized_keys") ]] &&
        echo -e "${INFO} SSH Key installed successfully!" || {
        echo -e "${ERROR} SSH key installation failed!"
        exit 1
    }
}

change_port() {
    echo -e "${INFO} Changing SSH port to ${SSH_PORT} ..."
    if [ $(uname -o) == Android ]; then
        [[ -z $(grep "Port " "$PREFIX/etc/ssh/sshd_config") ]] &&
            echo -e "${INFO} Port ${SSH_PORT}" >>$PREFIX/etc/ssh/sshd_config ||
            sed -i "s@.*\(Port \).*@\1${SSH_PORT}@" $PREFIX/etc/ssh/sshd_config
        [[ $(grep "Port " "$PREFIX/etc/ssh/sshd_config") ]] && {
            echo -e "${INFO} SSH port changed successfully!"
            RESTART_SSHD=2
        } || {
            RESTART_SSHD=0
            echo -e "${ERROR} SSH port change failed!"
            exit 1
        }
    else
        $SUDO sed -i "s@.*\(Port \).*@\1${SSH_PORT}@" /etc/ssh/sshd_config && {
            echo -e "${INFO} SSH port changed successfully!"
            RESTART_SSHD=1
        } || {
            RESTART_SSHD=0
            echo -e "${ERROR} SSH port change failed!"
            exit 1
        }
    fi
}

disable_password() {
    if [ $(uname -o) == Android ]; then
        sed -i "s@.*\(PasswordAuthentication \).*@\1no@" $PREFIX/etc/ssh/sshd_config && {
            RESTART_SSHD=2
            echo -e "${INFO} Disabled password login in SSH."
        } || {
            RESTART_SSHD=0
            echo -e "${ERROR} Disable password login failed!"
            exit 1
        }
    else
        $SUDO sed -i "s@.*\(PasswordAuthentication \).*@\1no@" /etc/ssh/sshd_config && {
            RESTART_SSHD=1
            echo -e "${INFO} Disabled password login in SSH."
        } || {
            RESTART_SSHD=0
            echo -e "${ERROR} Disable password login failed!"
            exit 1
        }
    fi
}

# ---------- 新增：智能重启 SSH 服务 ----------
restart_ssh() {
    # 检测当前运行的 SSH 进程名（如 sshd, ssh, opensshd）
    local detected_svc
    detected_svc=$(ps -eo comm= | grep -E 'sshd|opensshd|ssh' | head -n1)
    if [ -n "$detected_svc" ]; then
        echo -e "${INFO} Detected SSH process: $detected_svc"
    else
        detected_svc="sshd"  # fallback
    fi

    # 构建重启命令列表（同时尝试 ssh 和 sshd，覆盖 Ubuntu/CentOS 差异）
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

    # 去重执行
    local tried=()
    for cmd in "${cmds[@]}"; do
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
    echo -e "${INFO} Please restart manually using one of:"
    echo "  sudo systemctl restart ssh   # Ubuntu/Debian"
    echo "  sudo systemctl restart sshd  # CentOS/RHEL"
    echo "  sudo service ssh restart     # SysV init"
    return 1
}
# ---------------------------------------------------------

while getopts "og:u:f:p:d" OPT; do
    case $OPT in
    o)
        OVERWRITE=1
        ;;
    g)
        KEY_ID=$OPTARG
        get_github_key
        install_key
        ;;
    u)
        KEY_URL=$OPTARG
        get_url_key
        install_key
        ;;
    f)
        KEY_PATH=$OPTARG
        get_local_key   # 修正函数名
        install_key
        ;;
    p)
        SSH_PORT=$OPTARG
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

# 根据 RESTART_SSHD 标志执行重启
if [ "$RESTART_SSHD" = 1 ]; then
    if [ "$(uname -o)" = "Android" ]; then
        echo -e "${INFO} Restart sshd or Termux App to take effect."
    else
        restart_ssh
    fi
elif [ "$RESTART_SSHD" = 2 ]; then
    echo -e "${INFO} Restart sshd or Termux App to take effect."
fi

exit 0
