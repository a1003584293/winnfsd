#!/bin/bash
#
# 批量卸载之前挂载的 NFS 盘符（/Volumes/nfs_<盘符>）
#
# 用法:
#   chmod +x unmount_nfs.sh
#   ./unmount_nfs.sh

SERVER="192.168.0.112"          # 可选：仅卸载该服务器（留空则卸载所有 nfs_ 前缀挂载点）
MOUNT_ROOT="/Volumes"

set -e

sudo -v

echo "开始卸载 NFS 挂载..."
for mp in "${MOUNT_ROOT}"/nfs_*; do
    [ -e "${mp}" ] || continue

    if mount | grep -q " on ${mp} "; then
        if [ -z "${SERVER}" ] || mount | grep -q "^${SERVER}:" ; then
            sudo umount "${mp}" && echo "已卸载 ${mp}"
            rmdir "${mp}" 2>/dev/null || true
        else
            echo "跳过 ${mp}（不属于 ${SERVER}）"
        fi
    else
        echo "跳过 ${mp}（未挂载）"
    fi
done

echo
echo "卸载完成，当前 NFS 挂载情况："
mount | grep " on ${MOUNT_ROOT}/nfs_" || echo "（无 NFS 挂载）"