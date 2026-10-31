#!/bin/bash
#
# 批量挂载 WinNFSd 导出的盘符
#
# 同时尝试两条链路，哪条能连上就挂哪条，连不上自动跳过（不会中断整个脚本）：
#
#   Wi-Fi : 192.168.0.112:/D  ->  /Volumes/wireless/nfs_D
#   网线  : 169.254.x.x:/D    ->  /Volumes/line/nfs_D
#
# 用父目录区分链路：同一个盘可以同时出现在两处，各自独立走自己的网卡，
# 方便对比速度，也方便某条线拔掉后仍能用另一条。
#
# 用法:
#   chmod +x mount_nfs.sh
#   ./mount_nfs.sh

# ===== 配置 =====

# Wi-Fi 链路（无线路由器分配的地址）。留空则跳过 Wi-Fi 挂载。
WIRELESS_SERVER="192.168.0.112"

# 网线直连的地址。留空则自动探测（见 detect_wired_server），探测不到就跳过网线挂载。
# 网线第一次直连时 Windows 的 link-local 地址是随机的，自动探测往往拿不到；
# 建议在 Windows 上把有线网卡设成固定地址（例如 169.254.1.1/16），这里填上即可。
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

# ===== 辅助函数 =====

# Windows 跑着 WinNFSd 时 2049 端口一定开着；用它判断链路是否可用，
# 比 ping 可靠（Windows 默认可能屏蔽 ICMP）。
probe_server() {
    local host="$1"
    [ -n "${host}" ] || return 1
    nc -z -G "${PROBE_TIMEOUT}" "${host}" 2049 >/dev/null 2>&1
}

# 有线网口名（"Hardware Port: Ethernet" 对应的 Device，通常是 en0）。
wired_iface() {
    networksetup -listallhardwareports 2>/dev/null \
        | awk '/^Hardware Port: Ethernet$/{ getline; sub(/^Device: /, ""); print; exit }'
}

# 从 ARP 表里找一个 link-local 邻居，作为网线直连的候选地址。
#
# 只认有线口上、已经解析出 MAC 的条目：没插网线时 ARP 里会残留
# `(169.254.x.x) at (incomplete) on en1` 这样的失败记录，还挂在 Wi-Fi 口上，
# 直接取第一条会拿到一个永远连不上的地址。
detect_wired_server() {
    local iface
    iface="$(wired_iface)"
    [ -n "${iface}" ] || return 1

    arp -an 2>/dev/null \
        | grep -F " on ${iface} " \
        | awk '/\(169\.254\.[0-9]+\.[0-9]+\)/ && !/incomplete/ { gsub(/[()]/, "", $2); print $2 }' \
        | head -n 1
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

    local mounted=0 failed=0
    for d in "${DRIVES[@]}"; do
        if mount_drive "${server}" "${base}" "${d}"; then
            mounted=$((mounted + 1))
        else
            failed=$((failed + 1))
        fi
    done
    echo "  ${label} 完成：成功 ${mounted}，失败 ${failed}"
    echo
    return 0
}

# ===== 主流程 =====

# 不用 `set -e`：某条链路不可用时必须继续尝试另一条。
set -uo pipefail

MY_UID="$(id -u)"
MY_GID="$(id -g)"
echo "当前 Mac 用户 UID=${MY_UID} GID=${MY_GID}"
echo "（如果希望 NFS 上的文件归属显示成你自己的用户，请用下面参数启动 WinNFSd：）"
echo "    WinNFSd.exe -id ${MY_UID} ${MY_GID} -addr 0.0.0.0 -log -pathFile \"exports.txt\""
echo

# 网线地址：显式配置优先，否则自动探测。
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

if ${wireless_ok}; then
    mkdir -p "${WIRELESS_DIR}" 2>/dev/null || sudo mkdir -p "${WIRELESS_DIR}"
    mount_link "Wi-Fi" "${WIRELESS_SERVER}" "${WIRELESS_DIR}"
else
    echo "跳过 Wi-Fi（${WIRELESS_SERVER:-未配置} 不可达）"
    echo
fi

if ${wired_ok}; then
    mkdir -p "${WIRED_DIR}" 2>/dev/null || sudo mkdir -p "${WIRED_DIR}"
    mount_link "网线" "${WIRED_SERVER}" "${WIRED_DIR}"
else
    echo "跳过网线（${WIRED_SERVER:-未探测到地址}）"
    echo
fi

echo "挂载完成，当前 NFS 挂载情况："
mount | grep " on ${WIRELESS_DIR}/nfs_" || echo "（Wi-Fi 无挂载）"
mount | grep " on ${WIRED_DIR}/nfs_" || echo "（网线无挂载）"
