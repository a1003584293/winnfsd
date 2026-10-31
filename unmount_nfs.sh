#!/bin/bash
#
# 批量卸载 mount_nfs.sh 挂载的 NFS 盘符
#
# 覆盖两种布局：
#   /Volumes/wireless/nfs_<盘符>   （Wi-Fi 链路）
#   /Volumes/line/nfs_<盘符>       （网线直连）
#
# 卸载后删掉空的挂载点和父目录；父目录里还有别的挂载（例如另一个盘仍在使用）时保留。
#
# 用法:
#   chmod +x unmount_nfs.sh
#   ./unmount_nfs.sh            # 卸载全部
#   ./unmount_nfs.sh wireless   # 只卸载 Wi-Fi
#   ./unmount_nfs.sh line       # 只卸载网线

MOUNT_ROOT="/Volumes"

# mount_nfs.sh 钉住的路由记录在这里；卸载时一起清掉，
# 否则网线拔掉之后这些 host 路由还会把流量往已经不存在的网口上送。
STATE_DIR="${HOME}/Library/Caches/cardinal-nfs"
PINNED_ROUTES="${STATE_DIR}/pinned_routes"

# 可选参数：只处理某一条链路
ONLY_LINK="${1:-}"

# 不用 `set -e`：某个挂载点卸载失败（例如仍在读写）不应中断其余的卸载。
set -uo pipefail

unmount_one() {
    local mp="$1"
    echo "正在检查 ${mp}..."

    local mount_line
    mount_line="$(mount | grep -F " on ${mp} " || true)"
    if [ -z "${mount_line}" ]; then
        echo "  跳过（未挂载）"
        return 0
    fi

    echo "  正在卸载…（NFS 响应慢时可能要等一会）"
    if sudo umount "${mp}" 2>/dev/null; then
        echo "  已卸载"
        return 0
    fi

    # 有进程正在使用该挂载点时，umount 会失败；这时不应该强拆，先让用户知道。
    echo "  普通卸载失败，尝试强制卸载…" >&2
    if sudo umount -f "${mp}" 2>/dev/null; then
        echo "  已强制卸载"
        return 0
    fi

    echo "  卸载失败：${mp} 可能仍被占用（关闭正在读取该目录的程序后重试）" >&2
    return 1
}

unmount_link() {
    local label="$1" base="$2"
    echo "== ${label}（${base}）=="

    local cleaned=0
    for mp in "${base}"/nfs_*; do
        # 没有匹配项时 glob 会原样返回，跳过。
        [ -e "${mp}" ] || continue
        if unmount_one "${mp}"; then
            # 只有真正卸载成功（或本来就没挂载）才删目录。
            if [ -z "$(mount | grep -F " on ${mp} " || true)" ]; then
                rmdir "${mp}" 2>/dev/null || true
                cleaned=$((cleaned + 1))
            fi
        fi
    done

    # 父目录空了就一起删掉，避免 /Volumes 下留一堆空目录。
    if [ -d "${base}" ] && [ -z "$(ls -A "${base}" 2>/dev/null)" ]; then
        rmdir "${base}" 2>/dev/null || true
        echo "  已删除空目录 ${base}"
    fi
    echo
}

if [ -n "${ONLY_LINK}" ] && [ "${ONLY_LINK}" != "wireless" ] && [ "${ONLY_LINK}" != "line" ]; then
    echo "参数只能是 wireless 或 line（当前：${ONLY_LINK}）" >&2
    exit 2
fi

sudo -v

if [ -z "${ONLY_LINK}" ] || [ "${ONLY_LINK}" = "wireless" ]; then
    unmount_link "Wi-Fi" "${MOUNT_ROOT}/wireless"
fi

if [ -z "${ONLY_LINK}" ] || [ "${ONLY_LINK}" = "line" ]; then
    unmount_link "网线" "${MOUNT_ROOT}/line"
fi

# 兼容老布局：以前直接挂在 /Volumes/nfs_<盘符>，一并清理。
if [ -z "${ONLY_LINK}" ]; then
    legacy_found=false
    for mp in "${MOUNT_ROOT}"/nfs_*; do
        [ -e "${mp}" ] || continue
        if [ -z "$(mount | grep -F " on ${mp} " || true)" ]; then
            continue
        fi
        if ! ${legacy_found}; then
            echo "== 旧布局（/Volumes/nfs_<盘符>）=="
            legacy_found=true
        fi
        if unmount_one "${mp}"; then
            if [ -z "$(mount | grep -F " on ${mp} " || true)" ]; then
                rmdir "${mp}" 2>/dev/null || true
            fi
        fi
    done
    if ${legacy_found}; then
        echo
    fi
fi

# 清掉 mount_nfs.sh 为网线链路钉住的路由。
release_pinned_routes() {
    [ -s "${PINNED_ROUTES}" ] || return 0
    echo "== 清理网线钉住的路由 =="
    while read -r host iface; do
        [ -n "${host}" ] || continue
        if sudo route -n delete -host "${host}" 2>/dev/null; then
            echo "  已删除 ${host} -> ${iface} 的路由"
        else
            echo "  跳过 ${host}（没有对应路由）"
        fi
    done <"${PINNED_ROUTES}"
    rm -f "${PINNED_ROUTES}"
    echo
}

release_pinned_routes

echo "卸载完成，当前 NFS 挂载情况："
mount | grep -E " on (${MOUNT_ROOT}/(wireless|line)/nfs_|${MOUNT_ROOT}/nfs_)" || echo "（无 NFS 挂载）"
