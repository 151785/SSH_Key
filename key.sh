#!/usr/bin/env bash
#=============================================================
#  SSH Key Installer - Enhanced Edition  v3.0
#  Original: https://github.com/P3TERX/SSH_Key_Installer (v2.7)
#
#  适配: Debian 9~13 / Ubuntu 18.04~26.04 / CentOS-RHEL 7~10
#        Rocky / Alma / Oracle / Fedora / Alpine / Arch / openSUSE
#        Termux (Android)
#
#  本版修复要点:
#   1) sshd_config.d 优先级 —— 新系统主配置里 Include 了
#      sshd_config.d/*.conf，sshd 是"先读到先生效"，直接改主配置会被
#      drop-in（如 50-cloud-init.conf 的 PasswordAuthentication yes）覆盖。
#      本版写 00- 前缀 drop-in，并用 sshd -T 校验"实际生效值"，
#      若仍被覆盖则自动降级为"写入主配置 Include 之前"，确保生效。
#   2) ssh.socket 套接字激活 —— Ubuntu 22.10+/26.04 默认由 ssh.socket
#      监听端口，只改 sshd_config 的 Port 完全无效。本版自动写 socket
#      drop-in（ListenStream 重置+重设）并 daemon-reload + 重启 socket。
#   3) OpenSSH 10（Debian 13 / Ubuntu 26 自带）已移除 DSA，自动过滤 ssh-dss。
#   4) 不再依赖 `uname -o`（busybox 下会报错），改用 TERMUX_VERSION/PREFIX 探测。
#   5) sshd 用绝对路径（/usr/sbin/sshd）；校验用 sshd -t -f，生效值用 sshd -T；
#      服务名 ssh.service / sshd.service 自动识别，兼容 socket 激活。
#   6) 追加公钥不再插空行；多行公钥逐条去重；root 执行时按 SUDO_USER 落盘并 chown。
#   7) 选项改为"先解析后执行"，-o 可放任意位置；-p/-d 合并为一次编辑、一次重启。
#   8) 新增 -r 回滚到最近备份；任何校验失败自动回滚，防止改坏配置。
#   9) cloud-init 托管文件识别：命中 50-cloud-init.conf 这类文件时，会提示"重启后
#      可能被改回"；加 -C 自动写 /etc/cloud/cloud.cfg.d/99-ssh-key-installer.cfg
#      (ssh_pwauth: false) 永久生效，不加 -C 则打印可直接复制的一键命令。
#=============================================================

VERSION="3.0"
export LC_ALL=C

if [ -t 1 ]; then
    C_RED="\033[31m"; C_GREEN="\033[1;32m"; C_YELL="\033[33m"; C_OFF="\033[0m"
else
    C_RED=""; C_GREEN=""; C_YELL=""; C_OFF=""
fi
INFO="[${C_GREEN}INFO${C_OFF}]"
WARN="[${C_YELL}WARN${C_OFF}]"
ERROR="[${C_RED}ERROR${C_OFF}]"

info() { echo -e "${INFO} $*"; }
warn() { echo -e "${WARN} $*"; }
err()  { echo -e "${ERROR} $*" >&2; }
die()  { err "$*"; exit 1; }

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    fi
fi
as_root() {
    if [ -n "$SUDO" ]; then $SUDO "$@"; else "$@"; fi
}

USAGE() {
    cat <<EOF
SSH Key Installer $VERSION   (Debian 13 / Ubuntu 26 适配版)

用法:
  bash $(basename "$0") [选项] [参数]

公钥来源（三选一）:
  -g <GitHub ID>    从 GitHub 拉取公钥 (https://github.com/<ID>.keys)
  -u <URL>          从 URL 拉取公钥
  -f <文件路径>      从本地文件读取公钥

安装行为:
  -o                覆盖模式（重写 authorized_keys），需放在来源选项之前或之后均可
  -p <端口>         修改 SSH 端口（自动处理 sshd_config.d 与 ssh.socket）
  -d                禁用密码登录（会先检查是否存在可用公钥，防锁死）
  -C                同时关掉 cloud-init 的密码登录（写 /etc/cloud/cloud.cfg.d/），
                    防止云主机重启后把 PasswordAuthentication 改回 yes
  -r                回滚：恢复最近一次备份的 sshd_config / drop-in / cloud-init 配置
  -h                显示帮助

示例:
  bash key.sh -g p3terx                  # 装某人的 GitHub 公钥
  bash key.sh -f ~/id_ed25519.pub -d     # 装本地公钥并禁用密码登录
  bash key.sh -p 2222 -d                 # 改端口 + 禁密码（一次编辑一次重启）
  bash key.sh -d -C                      # 禁密码，并让 cloud-init 不再改回来
  bash key.sh -r                         # 改坏了？回滚

兼容: systemd / SysV / OpenRC / Termux，Debian 9~13、Ubuntu 18.04~26.04、
      CentOS-RHEL 7~10、Alpine、Arch、openSUSE。容器内无 systemd 亦可用。
EOF
}

#=============================================================
# 环境探测
#=============================================================
is_termux() {
    [ -n "${TERMUX_VERSION:-}" ] && return 0
    [ -d "/data/data/com.termux/files/usr" ] && return 0
    [ -n "${PREFIX:-}" ] && [ -x "${PREFIX}/bin/sshd" ] && return 0
    return 1
}

detect_env() {
    OS_ID="unknown"; OS_VER=""; OS_NAME=""
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release 2>/dev/null || true
        OS_ID="${ID:-unknown}"; OS_VER="${VERSION_ID:-}"; OS_NAME="${PRETTY_NAME:-$OS_ID}"
    fi
    if is_termux; then
        OS_ID="termux"; OS_NAME="Termux (Android)"
    fi

    # systemd 真的在跑才用 systemctl（容器里装了 systemd 也常是死的）
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        HAS_SYSTEMD=1
    else
        HAS_SYSTEMD=0
    fi

    # 目标用户：root 通过 sudo 调用时，装到真实用户的 home，而不是 /root
    TARGET_USER="$(id -un)"
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
        TARGET_USER="$SUDO_USER"
    fi
    TARGET_HOME="$(awk -F: -v u="$TARGET_USER" '$1==u{print $6}' /etc/passwd 2>/dev/null)"
    [ -n "$TARGET_HOME" ] || TARGET_HOME="${HOME:-/root}"
    TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")"
}

find_sshd_bin() {
    SSHD_BIN=""
    local c
    for c in "$(command -v sshd 2>/dev/null || true)" \
             /usr/sbin/sshd /usr/local/sbin/sshd /sbin/sshd /usr/bin/sshd \
             "${PREFIX:-/nonexistent}/bin/sshd"; do
        if [ -n "$c" ] && [ -x "$c" ]; then SSHD_BIN="$c"; return 0; fi
    done
    return 1
}

resolve_sshd_config() {
    local cand
    if is_termux; then
        SSHD_CONFIG="${PREFIX}/etc/ssh/sshd_config"
    elif [ -n "${SSHD_CONFIG_PATH:-}" ]; then          # 测试/自定义用
        SSHD_CONFIG="$SSHD_CONFIG_PATH"
    else
        SSHD_CONFIG=""
        for cand in /etc/ssh/sshd_config /usr/local/etc/ssh/sshd_config /opt/etc/ssh/sshd_config; do
            [ -f "$cand" ] && { SSHD_CONFIG="$cand"; break; }
        done
    fi
    [ -n "${SSHD_CONFIG:-}" ] && [ -f "$SSHD_CONFIG" ] || die "找不到 sshd_config（系统可能未安装 openssh-server）"

    CONF_DIR="$(dirname "$SSHD_CONFIG")"
    DROPIN_DIR=""; DROPIN_FILE=""
    # 只有"目录存在 + 主配置确实 Include 了它"时走 drop-in，老系统仍改主配置
    if ! is_termux && [ -d "${CONF_DIR}/sshd_config.d" ] && \
       grep -qiE '^[[:space:]]*Include[[:space:]]+.*sshd_config\.d' "$SSHD_CONFIG"; then
        DROPIN_DIR="${CONF_DIR}/sshd_config.d"
        DROPIN_FILE="${DROPIN_DIR}/00-ssh-key-installer.conf"
    fi
}

#=============================================================
# 备份 / 编辑 / 校验
#=============================================================
BK_FILES=(); BK_BACKUPS=()

# 备份为空字符串表示"该文件是本次运行新建的"，回滚时直接删除
backup_once() {
    local f="$1" b i
    [ -f "$f" ] || return 0
    for ((i = 0; i < ${#BK_FILES[@]}; i++)); do
        [ "${BK_FILES[i]}" = "$f" ] && return 0
    done
    b="${f}.bak.$(date +%Y%m%d%H%M%S)"
    as_root cp -a "$f" "$b" || die "备份失败: $b"
    BK_FILES+=("$f"); BK_BACKUPS+=("$b")
    info "已备份 $(basename "$f") → $b"
}

rollback_all() {
    local i
    [ "${#BK_FILES[@]}" -eq 0 ] && { warn "本次运行没有产生备份，未做回滚"; return 1; }
    for ((i = 0; i < ${#BK_FILES[@]}; i++)); do
        if [ -z "${BK_BACKUPS[i]}" ]; then
            as_root rm -f "${BK_FILES[i]}" 2>/dev/null
            warn "已移除本次新建的 $(basename "${BK_FILES[i]}")"
        else
            as_root cp -a "${BK_BACKUPS[i]}" "${BK_FILES[i]}" 2>/dev/null &&
                warn "已回滚 $(basename "${BK_FILES[i]}")"
        fi
    done
    return 0
}

fix_selinux() {
    local f="$1"
    if [ -d /sys/fs/selinux ] && command -v restorecon >/dev/null 2>&1; then
        as_root restorecon -RF "$f" 2>/dev/null || true
    fi
}

# 用临时文件回写，保留原 inode 的权限/属主
_commit_tmp() {
    local tmp="$1" f="$2"
    as_root cp "$tmp" "$f" || { rm -f "$tmp"; die "写入失败: $f"; }
    rm -f "$tmp"
    fix_selinux "$f"
}

# edit_conf <file> <key> <value>
# - 替换第一个 Match 块之前所有未注释的同名项
# - 不存在则插到第一个 Match 之前（避免被 Match 作用域吞掉），没有 Match 则追加
# - Match 块内部原样保留，不误伤
edit_conf() {
    local f="$1" key="$2" val="$3" tmp
    [ -f "$f" ] || die "文件不存在: $f"
    backup_once "$f"
    tmp="$(mktemp "${TMPDIR:-/tmp}/sshki.XXXXXX" 2>/dev/null || echo "/tmp/sshki.$$.tmp")"
    awk -v k="$key" -v v="$val" '
        { lines[NR] = $0 }
        END {
            lk = tolower(k); n = NR; repl = 0; midx = 0
            for (i = 1; i <= n; i++) {
                t = lines[i]; sub(/^[[:space:]]+/, "", t)
                if (midx == 0 && tolower(t) ~ /^match[[:space:]]/) midx = i
                if (midx > 0 && i >= midx) continue        # Match 块内不动
                if (t == "" || t ~ /^#/) continue
                split(t, a, /[[:space:]]+/)
                if (tolower(a[1]) == lk) { lines[i] = k " " v; repl = 1 }
            }
            if (repl) {
                for (i = 1; i <= n; i++) print lines[i]
            } else if (midx > 0) {
                for (i = 1; i < midx; i++) print lines[i]
                print k " " v
                for (i = midx; i <= n; i++) print lines[i]
            } else {
                for (i = 1; i <= n; i++) print lines[i]
                print k " " v
            }
        }' "$f" > "$tmp" || { rm -f "$tmp"; die "处理失败: $f"; }
    _commit_tmp "$tmp" "$f"
    info "写入 ${key} ${val} → $f"
}

# 兜底：插到主配置 Include 行之前（读得最早 → 一定生效）
force_main_conf() {
    local key="$1" val="$2" f="$SSHD_CONFIG" tmp
    backup_once "$f"
    tmp="$(mktemp "${TMPDIR:-/tmp}/sshki.XXXXXX" 2>/dev/null || echo "/tmp/sshki.$$.tmp")"
    awk -v k="$key" -v v="$val" '
        { lines[NR] = $0 }
        END {
            n = NR; inc = 0; midx = 0
            for (i = 1; i <= n; i++) {
                t = lines[i]; sub(/^[[:space:]]+/, "", t)
                if (inc  == 0 && tolower(t) ~ /^include[[:space:]]/) inc  = i
                if (midx == 0 && tolower(t) ~ /^match[[:space:]]/)   midx = i
            }
            pos = (inc > 0) ? inc : ((midx > 0) ? midx : 0)
            if (pos == 0) {
                for (i = 1; i <= n; i++) print lines[i]
                print k " " v
            } else {
                for (i = 1; i < pos; i++) print lines[i]
                print k " " v
                for (i = pos; i <= n; i++) print lines[i]
            }
        }' "$f" > "$tmp" || { rm -f "$tmp"; die "处理失败: $f"; }
    _commit_tmp "$tmp" "$f"
    warn "未能定位配置来源，已把 ${key} ${val} 写入主配置 Include 之前"
}

ensure_dropin() {
    [ -n "$DROPIN_FILE" ] || return 0
    [ -f "$DROPIN_FILE" ] && return 0
    printf '# Managed by SSH Key Installer %s\n# 00- 前缀保证在 sshd_config.d 中最早被读取\n' "$VERSION" \
        | as_root tee "$DROPIN_FILE" >/dev/null || die "无法创建 $DROPIN_FILE"
    as_root chmod 600 "$DROPIN_FILE" 2>/dev/null || true
    fix_selinux "$DROPIN_FILE"
    # 刚建的空白文件不需要备份，回滚时直接删除
    BK_FILES+=("$DROPIN_FILE"); BK_BACKUPS+=("")
    info "创建 drop-in: $DROPIN_FILE"
}

# 在指定文件的 [from,to] 行范围内找第一处未注释的 key，遇到 Match 即止（Match 内不算全局值）
# 输出: "行号<TAB>原行内容"
_find_in_file() {
    local f="$1" key="$2" from="${3:-1}" to="${4:-999999}"
    [ -f "$f" ] || return 1
    awk -v k="$key" -v a="$from" -v b="$to" '
        NR < a || NR > b { next }
        {
            t = $0; sub(/^[[:space:]]+/, "", t)
            if (tolower(t) ~ /^match[[:space:]]/) exit
            if (t == "" || t ~ /^#/) next
            split(t, p, /[[:space:]]+/)
            if (tolower(p[1]) == tolower(k)) { printf "%d\t%s\n", NR, $0; exit }
        }' "$f"
}

# 按 sshd 真实读取顺序定位"谁在决定这个选项"：
#   主配置 Include 之前 → sshd_config.d/*.conf（字母序） → 主配置 Include 之后
# 输出: "文件<TAB>行号<TAB>原行内容"
find_winner() {
    local key="$1" inc total f hit
    inc="$(grep -niE '^[[:space:]]*Include[[:space:]]+.*sshd_config\.d' "$SSHD_CONFIG" 2>/dev/null \
           | head -n1 | cut -d: -f1)"
    total="$(wc -l < "$SSHD_CONFIG" | tr -d ' ')"

    if [ -n "$inc" ]; then
        hit="$(_find_in_file "$SSHD_CONFIG" "$key" 1 "$((inc - 1))")"
        [ -n "$hit" ] && { printf '%s\t%s\n' "$SSHD_CONFIG" "$hit"; return 0; }

        if [ -n "$DROPIN_DIR" ] && [ -d "$DROPIN_DIR" ]; then
            # glob 在 LC_ALL=C 下按字节序展开，正是 sshd 读取 *.conf 的顺序
            for f in "$DROPIN_DIR"/*.conf; do
                [ -f "$f" ] || continue
                hit="$(_find_in_file "$f" "$key" 1 999999)"
                [ -n "$hit" ] && { printf '%s\t%s\n' "$f" "$hit"; return 0; }
            done
        fi

        hit="$(_find_in_file "$SSHD_CONFIG" "$key" "$((inc + 1))" "$total")"
        [ -n "$hit" ] && { printf '%s\t%s\n' "$SSHD_CONFIG" "$hit"; return 0; }
    else
        hit="$(_find_in_file "$SSHD_CONFIG" "$key" 1 "$total")"
        [ -n "$hit" ] && { printf '%s\t%s\n' "$SSHD_CONFIG" "$hit"; return 0; }
    fi
    return 1
}

# 找到真正的来源后，就地改那一行（比"再插一行然后祈祷顺序对"可靠）
fix_winner() {
    local key="$1" val="$2" winner wfile wline wbody
    if ! winner="$(find_winner "$key")"; then
        warn "未定位到 ${key} 的配置来源（可能来自 sshd 编译默认值）"
        return 1
    fi
    wfile="$(printf '%s' "$winner" | cut -f1)"
    wline="$(printf '%s' "$winner" | cut -f2)"
    wbody="$(printf '%s' "$winner" | cut -f3- | sed 's/^[[:space:]]*//')"

    info "${key} 的实际生效来源: $(basename "$wfile"):${wline} → ${wbody}"

    if [ "$wfile" = "$DROPIN_FILE" ]; then
        warn "来源是本脚本写入的 drop-in，却仍未生效，跳过就地修改"
        return 1
    fi
    backup_once "$wfile"
    as_root sed -i "${wline}s/.*/${key} ${val}/" "$wfile" || die "修改 $wfile 失败"
    fix_selinux "$wfile"
    info "已就地修正 $(basename "$wfile"):${wline} → ${key} ${val}"

    if is_cloud_init_managed "$wfile"; then
        cloud_init_hint "$wfile"
    fi
}

#=============================================================
# cloud-init：识别托管文件 + 永久化
#=============================================================
CLOUD_DIR="${CLOUD_DIR:-/etc/cloud}"
CLOUD_CFG="${CLOUD_DIR}/cloud.cfg.d/99-ssh-key-installer.cfg"

is_cloud_init_managed() {
    local f="$1" b
    [ -f "$f" ] || return 1
    b="$(basename "$f")"
    case "$b" in
        *cloud-init*|*cloud_init*|*cloudinit*) return 0 ;;
    esac
    head -n 8 "$f" 2>/dev/null | grep -qiE 'cloud-init|cloud_init|datasource|generated by' && return 0
    return 1
}

# 写 cloud-init drop-in（比 sed 改 cloud.cfg 安全，cloud.cfg.d/*.cfg 会覆盖主配置）
apply_cloud_init_fix() {
    [ "$CLOUD_FIXED" = "1" ] && return 0
    if [ ! -d "$CLOUD_DIR" ]; then
        warn "本机没有 ${CLOUD_DIR}，未安装 cloud-init，无需处理"
        CLOUD_FIXED=1
        return 1
    fi
    as_root mkdir -p "$(dirname "$CLOUD_CFG")" || die "无法创建 $(dirname "$CLOUD_CFG")"

    if [ -f "$CLOUD_CFG" ]; then
        backup_once "$CLOUD_CFG"
        if grep -qE '^[[:space:]]*ssh_pwauth:' "$CLOUD_CFG"; then
            as_root sed -i -E 's/^[[:space:]]*ssh_pwauth:.*/ssh_pwauth: false/' "$CLOUD_CFG" \
                || die "修改 $CLOUD_CFG 失败"
        else
            printf 'ssh_pwauth: false\n' | as_root tee -a "$CLOUD_CFG" >/dev/null \
                || die "写入 $CLOUD_CFG 失败"
        fi
    else
        printf '# Managed by SSH Key Installer %s\n# 禁止 cloud-init 重新打开密码登录（否则重启后 50-cloud-init.conf 又被写成 yes）\nssh_pwauth: false\n' \
            "$VERSION" | as_root tee "$CLOUD_CFG" >/dev/null || die "写入 $CLOUD_CFG 失败"
        as_root chmod 644 "$CLOUD_CFG" 2>/dev/null || true
        BK_FILES+=("$CLOUD_CFG"); BK_BACKUPS+=("")
    fi
    fix_selinux "$CLOUD_CFG"
    info "已写入 cloud-init 配置: ${CLOUD_CFG}  (ssh_pwauth: false)"
    info "cloud-init 在下次开机 / 重跑时才会重新生成 sshd 配置；当前 sshd 已即时生效"
    CLOUD_FIXED=1
    return 0
}

cloud_init_hint() {   # $1 = 被 cloud-init 托管的配置文件
    local f="$1"
    warn "该文件由 cloud-init 托管（$(basename "$f")），重启或重跑 cloud-init 后可能被改回原值"
    if [ "$CLOUD_FIX" = "1" ]; then
        apply_cloud_init_fix
        return 0
    fi
    info "让改动永久生效，二选一（推荐 A）："
    echo "   A. 重跑本脚本并加 -C，自动写入 cloud-init 配置（参数沿用你这次用的）："
    echo "      bash $0 -d -C"
    echo "   B. 复制这一行直接执行："
    echo "      sudo mkdir -p /etc/cloud/cloud.cfg.d && printf 'ssh_pwauth: false\n' | sudo tee ${CLOUD_CFG}"
    echo "   做完直接重启，或 sudo cloud-init clean --logs && sudo cloud-init init 验证"
}

# 即使本次没触发覆盖修正，只要 cloud-init 仍托管着 PasswordAuthentication yes，也提醒一次
check_cloud_init_conflict() {
    [ "$DISABLE_PW" = "1" ] || return 0
    [ -n "$DROPIN_DIR" ] && [ -d "$DROPIN_DIR" ] || return 0
    local f hit
    for f in "$DROPIN_DIR"/*.conf; do
        [ -f "$f" ] || continue
        [ "$f" = "$DROPIN_FILE" ] && continue
        is_cloud_init_managed "$f" || continue
        hit="$(_find_in_file "$f" PasswordAuthentication 1 999999)"
        [ -n "$hit" ] || continue
        case "$hit" in
            *[Yy][Ee][Ss]*) cloud_init_hint "$f"; return 0 ;;
        esac
    done
    return 0
}

apply_option() {
    local key="$1" val="$2"
    if [ -n "$DROPIN_FILE" ]; then
        ensure_dropin
        edit_conf "$DROPIN_FILE" "$key" "$val"
    else
        edit_conf "$SSHD_CONFIG" "$key" "$val"
    fi
}

validate_config() {
    [ -n "$SSHD_BIN" ] || { warn "未找到 sshd 可执行文件，跳过语法校验"; return 0; }
    local out
    if ! out="$(as_root "$SSHD_BIN" -t -f "$SSHD_CONFIG" 2>&1)"; then
        err "sshd 配置校验失败："
        printf '%s\n' "$out" | sed 's/^/    /' >&2
        return 1
    fi
    info "配置语法校验通过 (sshd -t)"
    return 0
}

# 取 sshd 实际生效值（sshd -T 展开 Include 与默认值）
effective_value() {
    local key="$1"
    [ -n "$SSHD_BIN" ] || return 1
    as_root "$SSHD_BIN" -T -f "$SSHD_CONFIG" 2>/dev/null \
        | awk -v k="$key" 'tolower($1)==tolower(k){print $2; exit}'
}

verify_effective() {   # $@ = "key=value" 列表；只报告，不修改
    local pair key val cur rc=0
    for pair in "$@"; do
        key="${pair%%=*}"; val="${pair#*=}"
        cur="$(effective_value "$key")"
        if [ -z "$cur" ]; then
            warn "无法通过 sshd -T 读取 ${key} 生效值，跳过该项校验"
            continue
        fi
        if [ "$cur" != "$val" ]; then
            warn "生效值与预期不符: ${key} 实际=${cur} 期望=${val}"
            rc=1
        else
            info "生效确认: ${key} = ${cur}"
        fi
    done
    return $rc
}

# 不生效时：定位真正的来源 → 就地改 → 再校验；仍不行才退化为写主配置
resolve_mismatch() {   # $@ = "key=value" 列表
    local pair key val cur fixed=0
    for pair in "$@"; do
        key="${pair%%=*}"; val="${pair#*=}"
        cur="$(effective_value "$key")"
        [ "$cur" = "$val" ] && continue
        warn "${key} 未按预期生效（实际=${cur:-未知}），开始定位覆盖来源…"
        fix_winner "$key" "$val" || force_main_conf "$key" "$val"
        fixed=1
    done
    [ "$fixed" = "1" ] || return 0

    validate_config || return 1

    for pair in "$@"; do
        key="${pair%%=*}"; val="${pair#*=}"
        cur="$(effective_value "$key")"
        if [ "$cur" != "$val" ]; then
            err "${key} 仍未生效（实际=${cur:-未知}）"
            return 1
        fi
        info "生效确认: ${key} = ${cur}"
    done
    return 0
}

#=============================================================
# 公钥获取
#=============================================================
fetch_url() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 30 "$url" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 30 -O - "$url" 2>/dev/null
    else
        die "需要 curl 或 wget 之一"
    fi
}

# 日志里只显示 scheme://host，隐藏 path/query（可能含个人标识或 token）
mask_url() {
    printf '%s' "$1" | sed -E 's#^([a-z]+://[^/?]+).*#\1/***#'
}

# 过滤掉注释/空行/过时算法（OpenSSH 10 已移除 DSA，装进去只会白写一行）
normalize_keys() {
    local raw="$1" bad=0
    printf '%s\n' "$raw" | tr -d '\r' | awk '
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*#/ { next }
        {
            t = $0; sub(/[[:space:]]+$/, "", t)
            split(t, a, /[[:space:]]+/)
            type = tolower(a[1])
            if (type == "ssh-dss") { print "!DSA! " t; next }
            if (type ~ /^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com|ssh-ed25519-cert-v01@openssh\.com|ssh-rsa-cert-v01@openssh\.com)$/)
                print t
            else
                print "!BAD! " t
        }'
}

collect_pubkey() {
    PUB_KEY=""
    local raw
    case "$KEY_SRC" in
        github)
            [ -n "$KEY_ID" ] || { read -r -e -p "请输入 GitHub 用户名: " KEY_ID; }
            [ -n "$KEY_ID" ] || die "输入为空"
            # 不回显账号：终端/日志可能被截图或共享
            info "正在从 GitHub 获取公钥..."
            raw="$(fetch_url "https://github.com/${KEY_ID}.keys")"
            if [ -z "$raw" ] || [ "$(printf '%s' "$raw" | head -c 20)" = "Not Found" ]; then
                die "该账号没有公开的 SSH 公钥（或账号不存在）"
            fi
            ;;
        url)
            [ -n "$KEY_URL" ] || { read -r -e -p "请输入公钥 URL: " KEY_URL; }
            [ -n "$KEY_URL" ] || die "输入为空"
            info "拉取: $(mask_url "$KEY_URL")"
            raw="$(fetch_url "$KEY_URL")"
            [ -n "$raw" ] || die "拉取失败或内容为空"
            ;;
        file)
            [ -n "$KEY_PATH" ] || { read -r -e -p "请输入本地公钥路径: " KEY_PATH; }
            [ -n "$KEY_PATH" ] || die "输入为空"
            [ -f "$KEY_PATH" ] || die "文件不存在: $KEY_PATH"
            info "读取: ${KEY_PATH}"
            raw="$(cat "$KEY_PATH" 2>/dev/null)" || die "读取失败"
            [ -n "$raw" ] || die "文件为空"
            ;;
        *) return 1 ;;
    esac

    local norm
    norm="$(normalize_keys "$raw")"
    if printf '%s\n' "$norm" | grep -q '^!DSA! '; then
        warn "检测到 DSA 公钥：OpenSSH 10（Debian 13 / Ubuntu 26）已移除该算法，已跳过"
    fi
    if printf '%s\n' "$norm" | grep -q '^!BAD! '; then
        warn "检测到无法识别的公钥行，已跳过：$(printf '%s\n' "$norm" | grep '^!BAD! ' | head -n1 | cut -c7-60)"
    fi
    PUB_KEY="$(printf '%s\n' "$norm" | grep -v '^!' | sort -u)"
    [ -n "$PUB_KEY" ] || die "没有可用的公钥（DSA 已淘汰，请改用 ed25519 / rsa）"
}

#=============================================================
# 安装公钥
#=============================================================
install_key() {
    [ -n "${PUB_KEY:-}" ] || die "没有可安装的公钥"
    # 兜底去重（覆盖模式下也不再写出重复行）
    PUB_KEY="$(printf '%s\n' "$PUB_KEY" | awk 'NF' | sort -u)"

    # 注意：不能写成 local a="..." b="${a}/..."，bash 会在赋值前展开 a
    local ssh_dir auth tmpk line
    local added=0
    ssh_dir="${TARGET_HOME}/.ssh"
    auth="${ssh_dir}/authorized_keys"

    as_root mkdir -p "$ssh_dir" || die "无法创建 $ssh_dir"
    as_root chmod 700 "$ssh_dir"
    [ -f "$auth" ] || { as_root touch "$auth" || die "无法创建 $auth"; }

    tmpk="$(mktemp "${TMPDIR:-/tmp}/sshki.keys.XXXXXX" 2>/dev/null || echo "/tmp/sshki.keys.$$")"
    printf '%s\n' "$PUB_KEY" > "$tmpk"

    if [ "$OVERWRITE" = "1" ]; then
        backup_once "$auth"
        as_root cp "$tmpk" "$auth" || die "写入 $auth 失败"
        added="$(wc -l < "$tmpk" | tr -d ' ')"
        rm -f "$tmpk"
        info "已覆盖写入 authorized_keys（${added} 条）"
    else
        # 确保原文件以换行结尾，避免新旧两行粘在一起
        if [ -s "$auth" ] && [ -n "$(tail -c 1 "$auth")" ]; then
            printf '\n' | as_root tee -a "$auth" >/dev/null
        fi
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            if as_root grep -Fxq -- "$line" "$auth" 2>/dev/null; then
                continue
            fi
            printf '%s\n' "$line" | as_root tee -a "$auth" >/dev/null || die "追加失败"
            added=$((added + 1))
        done < "$tmpk"
        rm -f "$tmpk"
        info "新增 ${added} 条公钥（已存在的不重复写入）"
    fi

    as_root chmod 600 "$auth"
    if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != "root" ]; then
        as_root chown -R "${TARGET_USER}:${TARGET_GROUP}" "$ssh_dir" 2>/dev/null || true
        as_root chmod go-w "$TARGET_HOME" 2>/dev/null || true   # sshd 拒绝 group/other 可写的 home
    fi
    fix_selinux "$ssh_dir"

    # 最终校验：文件里确实能读到公钥
    local n
    n="$(grep -cEv '^[[:space:]]*(#|$)' "$auth" 2>/dev/null)"; [ -n "$n" ] || n=0
    [ "$n" -gt 0 ] || die "authorized_keys 中没有任何公钥，安装失败"
    info "authorized_keys 现有 ${n} 条公钥（用户: ${TARGET_USER}）"
    KEY_INSTALLED=1
}

#=============================================================
# 端口 / 密码登录
#=============================================================
find_socket_unit() {
    SOCKET_UNIT=""
    [ "$HAS_SYSTEMD" = 1 ] || return 1
    local u
    for u in ssh.socket sshd.socket; do
        if systemctl list-unit-files --no-pager --no-legend "$u" 2>/dev/null | grep -q "^${u}"; then
            SOCKET_UNIT="$u"; return 0
        fi
    done
    return 1
}

ssh_socket_active() {
    [ "$HAS_SYSTEMD" = 1 ] || return 1
    find_socket_unit || return 1
    systemctl is-active --quiet "$SOCKET_UNIT" 2>/dev/null
}

configure_ssh_socket() {
    local port="$1" d="/etc/systemd/system/${SOCKET_UNIT}.d" f
    f="${d}/10-ssh-key-installer-port.conf"
    as_root mkdir -p "$d" || die "无法创建 $d"
    # 空的 ListenStream= 先清掉继承来的监听项，再写入新端口
    printf '[Socket]\nListenStream=\nListenStream=%s\n' "$port" | as_root tee "$f" >/dev/null \
        || die "写入 socket drop-in 失败"
    as_root chmod 644 "$f" 2>/dev/null || true
    fix_selinux "$d"
    info "SSH 由 ${SOCKET_UNIT} 托管，已写 socket drop-in: $f"
    as_root systemctl daemon-reload || warn "systemctl daemon-reload 失败"
    SOCKET_CHANGED=1
}

semanage_port() {
    local port="$1"
    [ -d /sys/fs/selinux ] || return 0
    command -v semanage >/dev/null 2>&1 || return 0
    if command -v selinuxenabled >/dev/null 2>&1 && ! selinuxenabled; then return 0; fi
    if semanage port -l 2>/dev/null | grep -qE "^ssh_port_t[[:space:]]+tcp[[:space:]].*\b${port}\b"; then
        return 0
    fi
    if as_root semanage port -a -t ssh_port_t -p tcp "$port" 2>/dev/null; then
        info "SELinux: 已为端口 ${port} 打上 ssh_port_t 标签"
    else
        as_root semanage port -m -t ssh_port_t -p tcp "$port" 2>/dev/null && \
            info "SELinux: 已更新端口 ${port} 的 ssh_port_t 标签" || \
            warn "SELinux: semanage 打标签失败，若无法连接请手动处理（setenforce 0 仅用于排查）"
    fi
}

change_port() {
    local port="$1" num
    case "$port" in
        ''|*[!0-9]*) die "端口必须是数字: ${port}" ;;
    esac
    # 10# 前缀避免 "022"/"08" 被当成八进制
    num=$((10#${port})) 2>/dev/null || die "端口不合法: ${port}"
    [ "$num" -ge 1 ] && [ "$num" -le 65535 ] || die "端口超出范围 (1-65535): ${port}"
    port="$num"

    info "修改 SSH 端口 → ${port}"
    apply_option Port "$port"

    # 关键：Ubuntu 22.10+ / 26.04 由 ssh.socket 监听端口，
    # 只改 sshd_config 的 Port 在 daemon-reload 前完全不生效
    if ssh_socket_active; then
        warn "检测到 ${SOCKET_UNIT} 套接字激活，端口需同步写入 socket 单元"
        configure_ssh_socket "$port"
    fi

    semanage_port "$port"
    CHANGE_PAIRS+=("Port=$port")
    NEED_RESTART=1
}

# 老系统（OpenSSH < 8.7）没有 KbdInteractiveAuthentication，只有 ChallengeResponseAuthentication
kbd_auth_keyword() {
    if [ -n "$SSHD_BIN" ] && as_root "$SSHD_BIN" -T 2>/dev/null | grep -qi '^kbdinteractiveauthentication'; then
        echo "KbdInteractiveAuthentication"
    else
        echo "ChallengeResponseAuthentication"
    fi
}

disable_password() {
    local kbd
    info "禁用密码登录"
    apply_option PasswordAuthentication no
    # 顺手关掉键盘交互认证，否则部分系统（PAM）仍会弹密码
    kbd="$(kbd_auth_keyword)"
    apply_option "$kbd" no
    CHANGE_PAIRS+=("PasswordAuthentication=no")
    NEED_RESTART=1
}

# 禁密码前检查有没有可用公钥，防止把自己锁在门外
guard_lockout() {
    local auth="${TARGET_HOME}/.ssh/authorized_keys" n
    n="$(grep -cEv '^[[:space:]]*(#|$)' "$auth" 2>/dev/null)"; [ -n "$n" ] || n=0
    if [ "$n" -le 0 ]; then
        err "拒绝执行：${auth} 里没有任何公钥"
        err "先装公钥再禁密码，否则会把自己锁在服务器外："
        err "  bash $0 -g <GitHub ID> -d"
        exit 1
    fi
    info "已确认 authorized_keys 中有 ${n} 条公钥，可安全禁用密码登录"
}

#=============================================================
# 重启 / 校验监听
#=============================================================
restart_ssh() {
    local ok=0 u

    if is_termux; then
        if command -v sv >/dev/null 2>&1 && [ -d "${PREFIX}/var/service/sshd" ]; then
            sv restart sshd 2>/dev/null && { info "已通过 runit 重启 sshd"; return 0; }
        fi
        as_root pkill -HUP -x sshd 2>/dev/null && info "已向 sshd 发送 SIGHUP" || \
            warn "请手动重启 Termux，或重新执行 sshd"
        return 0
    fi

    info "重启 SSH 服务..."

    if [ "$HAS_SYSTEMD" = 1 ]; then
        # socket 激活的系统：端口由 socket 决定，必须先动 socket
        if [ "$SOCKET_CHANGED" = 1 ] && [ -n "$SOCKET_UNIT" ]; then
            as_root systemctl restart "$SOCKET_UNIT" 2>/dev/null && ok=1
        fi
        for u in ssh.service sshd.service; do
            if systemctl list-unit-files --no-pager --no-legend "$u" 2>/dev/null | grep -q "^${u}"; then
                SSH_UNIT="$u"; break
            fi
        done
        [ -n "${SSH_UNIT:-}" ] || SSH_UNIT="ssh.service"
        if as_root systemctl restart "$SSH_UNIT" 2>/dev/null; then
            ok=1
        fi
        # 完全没有 sshd 服务（纯 socket 激活）时，socket 起来就算成功
        if [ "$ok" = 0 ] && ssh_socket_active; then ok=1; fi
        if [ "$ok" = 1 ]; then
            systemctl is-active --quiet "${SOCKET_UNIT:-none}" 2>/dev/null && \
                info "SSH socket 状态: $(systemctl is-active "$SOCKET_UNIT" 2>/dev/null)"
            if systemctl is-active --quiet "$SSH_UNIT" 2>/dev/null; then
                info "$SSH_UNIT 状态: active (running)"
            fi
        fi
    fi

    if [ "$ok" = 0 ] && command -v rc-service >/dev/null 2>&1; then
        for u in sshd ssh; do
            rc-service "$u" restart >/dev/null 2>&1 && { ok=1; info "OpenRC: 已重启 $u"; break; }
        done
    fi

    if [ "$ok" = 0 ] && command -v service >/dev/null 2>&1; then
        for u in ssh sshd; do
            service "$u" restart >/dev/null 2>&1 && { ok=1; info "SysV: 已重启 $u"; break; }
        done
    fi

    if [ "$ok" = 0 ]; then
        for u in /etc/init.d/sshd /etc/init.d/ssh; do
            [ -x "$u" ] && "$u" restart >/dev/null 2>&1 && { ok=1; info "init.d: 已重启 $u"; break; }
        done
    fi

    if [ "$ok" = 0 ]; then
        as_root pkill -HUP -x sshd 2>/dev/null && { ok=1; info "已向 sshd 发送 SIGHUP 重载配置"; }
    fi

    if [ "$ok" = 0 ]; then
        err "自动重启失败，请手动执行："
        echo "  sudo systemctl restart ssh         # Debian / Ubuntu（经典模式）"
        echo "  sudo systemctl restart ssh.socket  # Ubuntu 22.10+（socket 激活）"
        echo "  sudo systemctl restart sshd        # CentOS / RHEL / Arch"
        echo "  sudo service ssh restart           # SysV / OpenRC"
        return 1
    fi
    return 0
}

check_listen() {
    local port="$1"
    command -v ss >/dev/null 2>&1 || { warn "无 ss 命令，跳过监听检查"; return 0; }
    if ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]${port}\$"; then
        info "已确认端口 ${port} 处于监听状态"
        return 0
    fi
    warn "未检测到端口 ${port} 在监听，请检查："
    echo "  sudo ss -ltnp | grep ssh"
    [ "$HAS_SYSTEMD" = 1 ] && echo "  journalctl -u ssh -n 30 --no-pager"
    return 1
}

#=============================================================
# 回滚（-r）
#=============================================================
do_rollback() {
    local f newest n=0 base d
    # 1) 主配置
    if [ -n "$SSHD_CONFIG" ] && [ -f "$SSHD_CONFIG" ]; then
        newest="$(ls -1t "${SSHD_CONFIG}".bak.* 2>/dev/null | head -n1)"
        if [ -n "$newest" ]; then
            as_root cp -a "$newest" "$SSHD_CONFIG" || die "回滚失败: $SSHD_CONFIG"
            info "已从 $(basename "$newest") 恢复 $(basename "$SSHD_CONFIG")"
            n=$((n + 1))
        fi
    fi
    # 2) drop-in 目录（含被就地修正的第三方 conf）+ cloud-init 配置
    for d in "${DROPIN_DIR}" "${CLOUD_DIR}/cloud.cfg.d"; do
        [ -n "$d" ] && [ -d "$d" ] || continue
        for base in $(ls -1 "$d" 2>/dev/null \
                      | sed -n 's/^\(.*\)\.bak\.[0-9][0-9]*$/\1/p' | LC_ALL=C sort -u); do
            f="${d}/${base}"
            [ -f "$f" ] || continue
            newest="$(ls -1t "${f}".bak.* 2>/dev/null | head -n1)"
            if [ -n "$newest" ]; then
                as_root cp -a "$newest" "$f" || die "回滚失败: $f"
                info "已从 $(basename "$newest") 恢复 ${base}"
                n=$((n + 1))
            fi
        done
    done
    [ "$n" -gt 0 ] || die "没有找到备份文件（*.bak.*）"
    validate_config || die "回滚后的配置仍有语法错误，请手动检查"
    NEED_RESTART=1
}

#=============================================================
# 主流程
#=============================================================
main() {
    if [ $# -eq 0 ]; then USAGE; exit 1; fi

    OVERWRITE=0; KEY_SRC=""; KEY_ID=""; KEY_URL=""; KEY_PATH=""
    SSH_PORT=""; DISABLE_PW=0; DO_ROLLBACK=0; CLOUD_FIX=0; CLOUD_FIXED=0
    NEED_RESTART=0; SOCKET_CHANGED=0; KEY_INSTALLED=0
    SSH_UNIT=""; SOCKET_UNIT=""; CHANGE_PAIRS=()

    # 先解析全部参数，再统一执行（原版边解析边执行，-o 放后面会失效）
    local OPT
    OPTIND=1
    while getopts ":og:u:f:p:drhC" OPT; do
        case "$OPT" in
            o) OVERWRITE=1 ;;
            g) KEY_SRC="github"; KEY_ID="$OPTARG" ;;
            u) KEY_SRC="url";    KEY_URL="$OPTARG" ;;
            f) KEY_SRC="file";   KEY_PATH="$OPTARG" ;;
            p) SSH_PORT="$OPTARG" ;;
            d) DISABLE_PW=1 ;;
            C) CLOUD_FIX=1 ;;
            r) DO_ROLLBACK=1 ;;
            h) USAGE; exit 0 ;;
            :) err "选项 -$OPTARG 缺少参数"; USAGE; exit 1 ;;
            \?) err "未知选项 -$OPTARG"; USAGE; exit 1 ;;
        esac
    done

    [ "$(id -u)" -eq 0 ] || [ -n "$SUDO" ] || die "需要 root 权限（或安装 sudo）"
    [ -n "$SUDO" ] && $SUDO -v 2>/dev/null

    detect_env
    info "系统: ${OS_NAME} ${OS_VER}    目标用户: ${TARGET_USER}(${TARGET_HOME})"

    local need_conf=0
    [ -n "$SSH_PORT" ] && need_conf=1
    [ "$DISABLE_PW" = "1" ] && need_conf=1
    [ "$DO_ROLLBACK" = "1" ] && need_conf=1

    if [ "$need_conf" = "1" ]; then
        resolve_sshd_config
        find_sshd_bin || warn "未找到 sshd，将跳过配置校验"
        info "配置: ${SSHD_CONFIG}"
        [ -n "$DROPIN_FILE" ] && info "使用 drop-in: ${DROPIN_FILE}"
        [ -z "$DROPIN_FILE" ] && info "该配置未包含 sshd_config.d，直接改主配置"
    fi

    # ---- 回滚 ----
    if [ "$DO_ROLLBACK" = "1" ]; then
        do_rollback
        restart_ssh
        info "回滚完成"
        return 0
    fi

    # ---- 公钥 ----
    if [ -n "$KEY_SRC" ]; then
        collect_pubkey
        install_key
    fi

    # ---- 端口 / 密码登录 ----
    if [ "$need_conf" = "1" ]; then
        # 先做安全检查，避免改完端口才发现要禁密码却没有公钥
        if [ "$DISABLE_PW" = "1" ]; then guard_lockout; fi

        if [ -n "$SSH_PORT" ]; then change_port "$SSH_PORT"; fi
        if [ "$DISABLE_PW" = "1" ]; then disable_password; fi

        if ! validate_config; then
            rollback_all
            die "配置校验未通过，已回滚，未重启服务"
        fi

        # 生效校验：不生效就精确定位来源并就地修正，仍不行则回滚
        if ! verify_effective "${CHANGE_PAIRS[@]}"; then
            if ! resolve_mismatch "${CHANGE_PAIRS[@]}"; then
                rollback_all
                die "配置无法生效，已回滚。可手动排查：sshd -T | grep -iE '^(port|passwordauthentication) '"
            fi
        fi

        # cloud-init 托管文件即使这次没赢，也会在重启后把密码登录改回来 → 提前提醒/处理
        check_cloud_init_conflict

        # 端口变更后提示防火墙
        if [ -n "$SSH_PORT" ]; then
            if command -v ufw >/dev/null 2>&1 && as_root ufw status 2>/dev/null | grep -q "Status: active"; then
                warn "ufw 已启用，记得放行：sudo ufw allow ${SSH_PORT}/tcp"
            elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
                warn "firewalld 已启用，记得放行：sudo firewall-cmd --permanent --add-port=${SSH_PORT}/tcp && sudo firewall-cmd --reload"
            fi
        fi
    fi

    # ---- 单独给 -C：只处理 cloud-init，不改 sshd ----
    if [ "$CLOUD_FIX" = "1" ] && [ "$DISABLE_PW" != "1" ]; then
        warn "仅指定 -C：只关闭 cloud-init 的密码登录，不改动 sshd 配置"
        apply_cloud_init_fix
    fi

    # ---- 重启 ----
    if [ "$NEED_RESTART" = "1" ]; then
        restart_ssh
        [ -n "$SSH_PORT" ] && check_listen "$SSH_PORT"
        echo
        warn "请保持当前会话不要断开，另开一个终端验证成功后再关闭："
        if [ -n "$SSH_PORT" ]; then
            echo "    ssh -p ${SSH_PORT} ${TARGET_USER}@<服务器IP>"
        else
            echo "    ssh ${TARGET_USER}@<服务器IP>"
        fi
        echo "    回滚命令: bash $0 -r"
    fi

    if [ "$KEY_INSTALLED" = "1" ] && [ "$NEED_RESTART" = "0" ]; then
        info "公钥安装完成（authorized_keys 改动无需重启 sshd）"
    fi
    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
