#!/bin/bash
#
# 批量挂载 WinNFSd 导出的盘符到 /Volumes/nfs_<盘符>
#
# 用法:
#   chmod +x mount_nfs.sh
#   ./mount_nfs.sh
#
# 可先改下面两个变量（一般不用改，脚本会自动探测）

# NFS 服务器地址（Windows 机器的 IP）
SERVER="192.168.0.112"

# 要挂载的盘符列表（对应 exports.txt 里的别名 /D /E ...）
DRIVES=(D E F G H I K L N)

# 挂载点目录前缀
MOUNT_ROOT="/Volumes"

set -e

# 先探测本机 uid/gid（用于提示，实际是否生效取决于 WinNFSd 的 -id 参数）
MY_UID="$(id -u)"
MY_GID="$(id -g)"
echo "当前 Mac 用户 UID=${MY_UID} GID=${MY_GID}"
echo "（如果希望 NFS 上的文件归属显示成你自己的用户，请用下面参数启动 WinNFSd：）"
echo "    WinNFSd.exe -id ${MY_UID} ${MY_GID} -addr 0.0.0.0 -log -allownonroot -pathFile \"exports.txt\""
echo

# 让 sudo 提前输入一次密码，后续挂载不再逐个询问
sudo -v

echo "开始挂载 NFS 盘符..."
for d in "${DRIVES[@]}"; do
    mount_point="${MOUNT_ROOT}/nfs_${d}"
    export_path=":/${d}"

    # 创建挂载点目录
    sudo mkdir -p "${mount_point}"

    # 已挂载则跳过
    if mount | grep -q " on ${mount_point} "; then
        echo "跳过 ${mount_point}（已挂载）"
        continue
    fi

    # 挂载（nolock 必须，因为 WinNFSd 不实现 NLM 文件锁）
    sudo mount -t nfs -o nolock,vers=3 "${SERVER}${export_path}" "${mount_point}"

    echo "已挂载 ${SERVER}${export_path} -> ${mount_point}"
done

echo
echo "挂载完成，当前 NFS 挂载情况："
mount | grep " on ${MOUNT_ROOT}/nfs_" || echo "（无）"