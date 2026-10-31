#!/bin/bash
#
# 批量挂载 WinNFSd 导出的盘符
#
# 默认**只挂一条链路**，优先网线，网线不可用才退回 Wi-Fi：
#
#   Wi-Fi : 192.168.0.112:/D  ->  /Volumes/wireless/nfs_D
#   网线  : 169.254.x.x:/D    ->  /Volumes/line/nfs_D
#
# 为什么不两条一起挂：WinNFSd 在 `winnfsd.cpp` 里把并发连接数写死了
#
#     ServerSockets[1].Open(NFS_PORT,   20);   // 2049 最多 20 条连接
#     ServerSockets[2].Open(MOUNT_PORT,  3);   // 1058 最多 3 条
#
# 而 `CServerSocket::Run()` 在槽位占满时会把 accept 到的 socket **直接丢掉**
# （既不处理也不关闭），客户端就只能干等到超时，报
# `can't mount ... Operation timed out`。macOS 每个挂载点固定占 1 条 2049 连接，
# 9 个盘 × 2 条链路 = 18 条，还在 20 以内；默认仍只挂一条，是因为两条一起挂
# 只会互相抢带宽。
#
# 用法:
#   chmod +x mount_nfs.sh
#   ./mount_nfs.sh              # 自动：网线优先，不可用则 Wi-Fi
#   ./mount_nfs.sh line         # 只挂网线
#   ./mount_nfs.sh wireless     # 只挂 Wi-Fi
#   ./mount_nfs.sh both         # 两条都挂（18 条连接，仍在 20 条上限内）

# ===== 配置 =====

# Wi-Fi 链路（无线路由器分配的地址）。留空则跳过 Wi-Fi 挂载。
WIRELESS_SERVER="192.168.0.112"

# 网线直连的地址。留空则自动探测（见 detect_wired_server），探测不到就跳过网线挂载。
# 直连时没有 DHCP，Windows 和 Mac 都会退到 link-local（169.254.x.x/16），互通没问题。
# 想让探测更稳，可以在 Windows 上把有线网卡设成固定地址 169.254.1.1/16，这里填上即可。
WIRED_SERVER=""

# 要挂载的盘符列表
DRIVES=(D E F G H I K L N)

# exports.txt 里别名除了盘符之外的前缀。
#
# Finder 显示 NFS 卷用的是「服务器:/导出路径」的最后一段，**不是挂载点名字**。
# 所以现在 `D:\ > /D` 会让 Finder 里显示 "D"，即使挂载点是 /Volumes/wireless/nfs_D。
#
# 想让 Finder 也显示 nfs_D，把 Windows 上 exports.txt 改成：
#     D:\ > /nfs_D
# 重启 WinNFSd 后，把下面改成 EXPORT_PREFIX="nfs_" 即可。
EXPORT_PREFIX=""

# 挂载点父目录
MOUNT_ROOT="/Volumes"
WIRELESS_DIR="${MOUNT_ROOT}/wireless"
WIRED_DIR="${MOUNT_ROOT}/line"

# NFS 客户端参数。
#
# `nolock` 是必须的：WinNFSd 不实现 NLM 文件锁。
#
# `rsize`/`wsize`/`readahead` 决定单条读请求的吞吐上限（在途窗口 = rsize × readahead）：
#   默认 32KB × 16 = 512KB，在 Wi-Fi 抖动下只有 5~14 MB/s；
#   1MB × 8 = 8MB，实测 Wi-Fi 单流 11 MB/s、5 流合计 33 MB/s（已跑满 288 Mbps 链路）。
# 继续加大不会更快，只会多占内存——瓶颈已经是链路带宽，不是窗口大小。
# 取值约束见 `man 8 mount_nfs`：rsize 需为 4096 的倍数，readahead 范围 0~128。
NFS_OPTS="nolock,vers=3,rsize=1048576,wsize=1048576,readahead=8"

# 探测超时（秒）。网线没插时 nc 会立刻失败，这个值只影响无响应的情况。
PROBE_TIMEOUT=2

# WinNFSd 写死的 2049 并发连接上限，见 `winnfsd/src/winnfsd.cpp` 的
# `ServerSockets[1].Open(NFS_PORT, 20)`。macOS 每个挂载点占 1 条，所以这个数字
# 就是"这台服务器最多能被挂几个盘"。
WINNFSD_MAX_CLIENTS=20

# ===== 辅助函数 =====

# Windows 跑着 WinNFSd 时 2049 端口一定开着；用它判断链路是否可用，
# 比 ping 可靠（Windows 默认可能屏蔽 ICMP）。
probe_server() {
    local host="$1"
    [ -n "${host}" ] || return 1
    nc -z -G "${PROBE_TIMEOUT}" "${host}" 2049 >/dev/null 2>&1
}

# 上次成功的网线地址和本次钉住的路由，跨脚本共享。
STATE_DIR="${HOME}/Library/Caches/cardinal-nfs"
WIRED_CACHE="${STATE_DIR}/wired_server"
PINNED_ROUTES="${STATE_DIR}/pinned_routes"

# 有线网口名（"Hardware Port: Ethernet" 对应的 Device，通常是 en0）。
wired_iface() {
    networksetup -listallhardwareports 2>/dev/null \
        | awk '/^Hardware Port: Ethernet$/{ getline; sub(/^Device: /, ""); print; exit }'
}

# 有线口的 link-local 地址；取不到就说明网线没插上或没拿到地址。
wired_iface_addr() {
    local iface="$1"
    [ -n "${iface}" ] || return 1
    ifconfig "${iface}" 2>/dev/null \
        | awk '/inet 169\.254\./{ print $2; exit }'
}

# 有线口的速率信息，用来确认网线真的协商上了（例如 media: autoselect (1000baseT <full-duplex>)）。
wired_iface_media() {
    local iface="$1"
    ifconfig "${iface}" 2>/dev/null | awk -F'\t' '/\tmedia: /{ print $2; exit }'
}

# 从 ARP 表里找一个 link-local 邻居，作为网线直连的候选地址。
#
# 只认有线口上、已经解析出 MAC 的条目：没插网线时 ARP 里会残留
# `(169.254.x.x) at (incomplete) on en1` 这样的失败记录，还挂在 Wi-Fi 口上，
# 直接取第一条会拿到一个永远连不上的地址。
detect_wired_server() {
    local iface self_addr
    iface="$(wired_iface)"
    [ -n "${iface}" ] || return 1

    # 有线口没拿到 link-local 地址，说明网线没插好，ARP 表里的东西都不可信。
    self_addr="$(wired_iface_addr "${iface}")"
    [ -n "${self_addr}" ] || return 1

    # 直连时没人广播，ARP 表可能还是空的。往 link-local 广播地址发两包，
    # 逼对端回一个 ARP 响应，条目就出来了。
    ping -c 2 -t 1 -W 300 169.254.255.255 >/dev/null 2>&1 || true

    # 只认有线口上、已经解析出 MAC 的 link-local 条目：
    #   - `incomplete` 是没通的失败记录；
    #   - `permanent` 是本机自己的地址（`arp -an` 也会列出来），必须排除，
    #     否则会把自己的 IP 当成服务器，后面永远挂载失败；
    #   - 顺带排掉 self_addr，双保险。
    arp -an 2>/dev/null \
        | grep -F " on ${iface} " \
        | grep -v 'incomplete' \
        | grep -v 'permanent' \
        | awk -v self="${self_addr}" \
            '/\(169\.254\.[0-9]+\.[0-9]+\)/ { gsub(/[()]/, "", $2); if ($2 != self) print $2 }' \
        | head -n 1
}

# 把目标地址钉到有线口上。
#
# 只让 ARP 决定走哪条路是不够的：之前用 Wi-Fi 试过 169.254.x.x 之后，
# 路由表和 ARP 里会留下一个指向 en1 的残留条目，而它的优先级比后来新增的
# `169.254/16 -> en0` 更高。结果就是挂载成功了，但流量还是绕回了 Wi-Fi，
# 速度上不去还查不出原因。显式钉一条 host 路由最稳。
pin_route() {
    local host="$1" iface="$2"
    [ -n "${host}" ] && [ -n "${iface}" ] || return 0

    # 路由已经指向有线口就不用动，避免每次运行都往记录文件里追加重复条目。
    local current
    current="$(route -n get -host "${host}" 2>/dev/null | awk '/interface:/{ print $2; exit }')"
    if [ "${current}" = "${iface}" ]; then
        echo "  ${host} 已走 ${iface}，无需调整路由"
        return 0
    fi

    if sudo route -n change -host "${host}" -interface "${iface}" 2>/dev/null \
        || sudo route -n add -host "${host}" -interface "${iface}" 2>/dev/null; then
        echo "  已把 ${host} 的流量钉到 ${iface}（原来走 ${current:-默认路由}）"
        mkdir -p "${STATE_DIR}" 2>/dev/null || true
        printf '%s %s\n' "${host}" "${iface}" >>"${PINNED_ROUTES}"
        return 0
    fi
    echo "  警告：无法把 ${host} 钉到 ${iface}，路由可能仍走 Wi-Fi" >&2
    return 1
}

# 挂载一个盘符。返回 0 成功（含"已挂载"），1 失败。
mount_drive() {
    local server="$1" base="$2" drive="$3"
    local mount_point="${base}/nfs_${drive}"
    local export_path=":/${EXPORT_PREFIX}${drive}"

    local mount_line
    mount_line="$(mount | grep -F " on ${mount_point} " || true)"
    if [ -n "${mount_line}" ]; then
        if [[ "${mount_line}" == "${server}:"* ]]; then
            # 已有挂载：确认它还活着。NFS 服务器重启后句柄会失效。
            local probe_error probe_status
            probe_error="$(ls -A "${mount_point}" 2>&1 >/dev/null)" && probe_status=0 || probe_status=$?
            if [ "${probe_status}" -eq 0 ]; then
                echo "  跳过 ${mount_point}（已挂载）"
                return 0
            fi
            echo "  ${mount_point} 挂载已失效（${probe_error}），强制卸载后重挂..."
            sudo umount -f "${mount_point}" 2>/dev/null || true
        else
            echo "  跳过 ${mount_point}（已由其他来源挂载）"
            return 0
        fi
    fi

    if ! sudo mkdir -p "${mount_point}"; then
        echo "  无法创建挂载点 ${mount_point}" >&2
        return 1
    fi
    if sudo mount -t nfs -o "${NFS_OPTS}" "${server}${export_path}" "${mount_point}"; then
        echo "  已挂载 ${server}${export_path} -> ${mount_point}"
        return 0
    fi
    echo "  挂载失败 ${server}${export_path} -> ${mount_point}" >&2
    rmdir "${mount_point}" 2>/dev/null || true
    return 1
}

# 挂载一条链路下的所有盘符。任一盘失败不影响其它盘。
mount_link() {
    local label="$1" server="$2" base="$3"
    echo "${label}：${server} -> ${base}"

    local mounted=0 failed=0 first=true
    for d in "${DRIVES[@]}"; do
        # 1058（mountd）只有 3 个槽位，客户端断开后服务端要过一小会儿才把槽位标回空闲。
        # 连续挂载时等半秒，避免下一个盘撞上还没回收的槽位而超时。
        if ! ${first}; then
            sleep 0.5
        fi
        first=false
        if mount_drive "${server}" "${base}" "${d}"; then
            mounted=$((mounted + 1))
        else
            failed=$((failed + 1))
        fi
    done
    echo "  ${label} 完成：成功 ${mounted}，失败 ${failed}"
    if [ "${failed}" -gt 0 ]; then
        echo "  提示：如果报的是 Operation timed out，多半是 WinNFSd 的 ${WINNFSD_MAX_CLIENTS} 条连接被占满了。" >&2
        echo "        先 ./unmount_nfs.sh 全部卸掉，必要时在 Windows 上跑 restart-nfsd.bat 清空泄漏的槽位。" >&2
    fi
    echo
    return 0
}

# 到某台服务器的 2049 端口上还开着多少条 ESTABLISHED 连接（= 占掉多少 WinNFSd 槽位）。
nfs_conn_count() {
    local host="$1"
    [ -n "${host}" ] || { echo 0; return 0; }
    netstat -an -f inet 2>/dev/null \
        | awk -v h="${host}.2049" 'index($0, h) && /ESTABLISHED/ { n++ } END { print n + 0 }'
}

# 某个链路目录下当前挂了几个盘。
link_mount_count() {
    local base="$1"
    mount 2>/dev/null | grep -c " on ${base}/nfs_" || true
}

# 交互式确认；没有终端时按默认值返回。
ask_yes_no() {
    local prompt="$1" default="${2:-y}"
    if [ ! -t 0 ]; then
        [ "${default}" = "y" ]
        return
    fi
    local reply
    read -r -p "${prompt}" reply
    reply="${reply:-${default}}"
    case "${reply}" in
    [Yy]*) return 0 ;;
    *) return 1 ;;
    esac
}

# 卸掉一条链路上的所有挂载，用于同一时间只保留一条链路。
drop_link_mounts() {
    local label="$1" base="$2"
    local mp
    for mp in "${base}"/nfs_*; do
        [ -e "${mp}" ] || continue
        [ -n "$(mount | grep -F " on ${mp} " || true)" ] || continue
        echo "  卸载 ${mp}…"
        sudo umount "${mp}" 2>/dev/null || sudo umount -f "${mp}" 2>/dev/null || {
            echo "  ${mp} 仍被占用，请关闭正在读取它的程序后重试" >&2
            return 1
        }
    done
    echo "  已清空 ${label}"
    return 0
}

# ===== 主流程 =====

# 不用 `set -e`：某条链路不可用时必须继续尝试另一条。
set -uo pipefail

# auto = 网线优先；line / wireless = 只用那一条；both = 两条都挂（仅对比用）。
LINK_MODE="${1:-auto}"
case "${LINK_MODE}" in
auto | line | wireless | both) ;;
*)
    echo "参数只能是 auto / line / wireless / both（当前：${LINK_MODE}）" >&2
    exit 2
    ;;
esac

MY_UID="$(id -u)"
MY_GID="$(id -g)"
echo "当前 Mac 用户 UID=${MY_UID} GID=${MY_GID}"
echo "（如果希望 NFS 上的文件归属显示成你自己的用户，请用下面参数启动 WinNFSd：）"
echo "    WinNFSd.exe -id ${MY_UID} ${MY_GID} -addr 0.0.0.0 -log -pathFile \"exports.txt\""
echo

# 网线地址：显式配置优先，其次上次成功用过的地址，最后自动探测。
if [ -z "${WIRED_SERVER}" ] && [ -s "${WIRED_CACHE}" ]; then
    WIRED_SERVER="$(head -n 1 "${WIRED_CACHE}")"
    [ -n "${WIRED_SERVER}" ] && echo "沿用上次的网线地址：${WIRED_SERVER}"
fi
if [ -z "${WIRED_SERVER}" ]; then
    WIRED_SERVER="$(detect_wired_server)"
    if [ -n "${WIRED_SERVER}" ]; then
        echo "自动探测到网线直连地址：${WIRED_SERVER}"
    else
        echo "未探测到网线直连地址，将只挂 Wi-Fi"
        echo "（网线直连时建议在 Windows 上把有线网卡设为固定地址 169.254.1.1/16，"
        echo "  然后把本脚本的 WIRED_SERVER 改成 169.254.1.1）"
    fi
fi

# 打印有线口状态，方便确认网线是否真的协商上了。en0 是 2.5G 口，
# 对端是千兆就会显示 1000baseT，速率上限也就是 1000 Mbps（约 110 MB/s）。
WIRED_IFACE="$(wired_iface)"
if [ -n "${WIRED_IFACE}" ]; then
    WIRED_MEDIA="$(wired_iface_media "${WIRED_IFACE}")"
    case "${WIRED_MEDIA}" in
    "" | *inactive* | *none*)
        echo "网线口 ${WIRED_IFACE}：未连接（网线没插好或对端未上电）"
        ;;
    *)
        echo "网线口 ${WIRED_IFACE}：${WIRED_MEDIA}"
        echo "  本机地址：$(wired_iface_addr "${WIRED_IFACE}" || echo 未分配 link-local)"
        ;;
    esac
fi
echo

# 先确认至少一条链路可用，否则提前退出，避免白输入密码。
wireless_ok=false
wired_ok=false
probe_server "${WIRELESS_SERVER}" && wireless_ok=true
probe_server "${WIRED_SERVER}" && wired_ok=true

if ! ${wireless_ok} && ! ${wired_ok}; then
    echo "两条链路都连不上 WinNFSd（2049 端口无响应），请确认 Windows 上服务已启动。" >&2
    exit 1
fi

# 只为可用的链路获取 sudo 凭据。
sudo -v

# 网线链路：先把地址钉到有线口再探测一次，避免残留路由把流量带走而误判成"连不上"。
if ${wired_ok} && [ -n "${WIRED_IFACE}" ]; then
    pin_route "${WIRED_SERVER}" "${WIRED_IFACE}" || true
    if ! probe_server "${WIRED_SERVER}"; then
        echo "网线地址 ${WIRED_SERVER} 钉住路由后仍不可达，跳过网线" >&2
        wired_ok=false
    fi
fi

# 决定这条命令实际要挂哪几条链路。
use_wireless=false
use_wired=false
case "${LINK_MODE}" in
line)
    ${wired_ok} && use_wired=true || echo "网线不可用，${LINK_MODE} 模式下不挂任何盘" >&2
    ;;
wireless)
    ${wireless_ok} && use_wireless=true || echo "Wi-Fi 不可用，${LINK_MODE} 模式下不挂任何盘" >&2
    ;;
both)
    use_wireless=${wireless_ok}
    use_wired=${wired_ok}
    echo "同时挂两条链路：9 × 2 = 18 条 2049 连接，未超过 WinNFSd 的 ${WINNFSD_MAX_CLIENTS} 条上限。" >&2
    echo "两条链路读写的是同一个 WinNFSd 进程和同一批磁盘，只建议用来对比速度。" >&2
    echo
    ;;
auto)
    if ${wired_ok}; then
        use_wired=true
        echo "网线可用（延迟约 0.4 ms，Wi-Fi 约 4 ms），只挂网线。"
    elif ${wireless_ok}; then
        use_wireless=true
        echo "网线不可用，退回 Wi-Fi。"
    fi
    echo
    ;;
esac

if ${use_wireless} && ${use_wired}; then
    echo "两条链路都会挂载，跳过互斥检查。"
    echo
else
    # 单链路模式：另一条链路上残留的挂载会白占 WinNFSd 的连接槽，必须先清掉。
    if ${use_wired} && [ "$(link_mount_count "${WIRELESS_DIR}")" -gt 0 ]; then
        echo "Wi-Fi 上还有 $(link_mount_count "${WIRELESS_DIR}") 个挂载，会继续占着 WinNFSd 的连接槽。"
        if ask_yes_no "先卸载 Wi-Fi 上的挂载？[Y/n] " y; then
            drop_link_mounts "Wi-Fi" "${WIRELESS_DIR}" || exit 1
        else
            echo "保留 Wi-Fi 挂载，本次网线挂载会再多占 ${#DRIVES[@]} 条槽位。" >&2
        fi
        echo
    fi
    if ${use_wireless} && [ "$(link_mount_count "${WIRED_DIR}")" -gt 0 ]; then
        echo "网线上还有 $(link_mount_count "${WIRED_DIR}") 个挂载，会继续占着 WinNFSd 的连接槽。"
        if ask_yes_no "先卸载网线上的挂载？[Y/n] " y; then
            drop_link_mounts "网线" "${WIRED_DIR}" || exit 1
        else
            echo "保留网线挂载，本次 Wi-Fi 挂载会再多占 ${#DRIVES[@]} 条槽位。" >&2
        fi
        echo
    fi
fi

# 挂之前先看一眼服务端槽位还剩多少，撞上限时能立刻知道原因。
target_server=""
${use_wired} && target_server="${WIRED_SERVER}"
${use_wireless} && target_server="${target_server:-${WIRELESS_SERVER}}"
if [ -n "${target_server}" ]; then
    used="$(nfs_conn_count "${target_server}")"
    planned=0
    ${use_wireless} && planned=$((planned + ${#DRIVES[@]}))
    ${use_wired} && planned=$((planned + ${#DRIVES[@]}))
    echo "WinNFSd 连接占用：${used}/${WINNFSD_MAX_CLIENTS}（本次要挂 ${planned} 个盘）"
    if [ "${used}" -ge "${WINNFSD_MAX_CLIENTS}" ]; then
        echo "  已经是满的，新挂载一定会 Operation timed out。" >&2
        echo "  先 ./unmount_nfs.sh，或在 Windows 上跑 restart-nfsd.bat 清掉泄漏的槽位。" >&2
    elif [ "$((used + planned))" -gt "${WINNFSD_MAX_CLIENTS}" ]; then
        echo "  注意：${used} + ${planned} 超过 ${WINNFSD_MAX_CLIENTS}，后面几个盘会超时。" >&2
    fi
    echo
fi

if ${use_wireless}; then
    mkdir -p "${WIRELESS_DIR}" 2>/dev/null || sudo mkdir -p "${WIRELESS_DIR}"
    mount_link "Wi-Fi" "${WIRELESS_SERVER}" "${WIRELESS_DIR}"
else
    echo "跳过 Wi-Fi"
    echo
fi

if ${use_wired}; then
    mkdir -p "${WIRED_DIR}" 2>/dev/null || sudo mkdir -p "${WIRED_DIR}"
    mount_link "网线" "${WIRED_SERVER}" "${WIRED_DIR}"
    mkdir -p "${STATE_DIR}" 2>/dev/null || true
    printf '%s\n' "${WIRED_SERVER}" >"${WIRED_CACHE}"
else
    echo "跳过网线"
    echo
fi

echo "挂载完成，当前 NFS 挂载情况："
mount | grep " on ${WIRELESS_DIR}/nfs_" || echo "（Wi-Fi 无挂载）"
mount | grep " on ${WIRED_DIR}/nfs_" || echo "（网线无挂载）"
