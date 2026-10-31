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
#
# 用网线直连时改成有线网卡的地址（169.254.x.x 或手工设置的静态地址）：
#   192.168.0.112 → 走 Wi-Fi
#   169.254.x.x   → 走网线（Mac 的路由表会把 link-local 段指向 en0）
# WinNFSd 用 `-addr 0.0.0.0` 启动时会监听所有网卡，所以两种地址都能挂载，
# 具体走哪条链路由这里填的地址决定。
SERVER="192.168.0.112"

# NFS 客户端参数。
#
# `nolock` 是必须的：WinNFSd 不实现 NLM 文件锁。
#
# `rsize`/`wsize`/`readahead` 决定单条读请求的吞吐上限：
#   在途窗口 = rsize × readahead
#   实测值：默认 rsize=32768 + readahead=16 → 窗口 512KB，
#   在 Wi-Fi 抖动（RTT 3~250ms）下只有 14~24 MB/s；
#   改为 rsize=1MB + readahead=8 → 窗口 8MB，足以跑满千兆有线（约 110 MB/s）。
# 取值约束见 `man 8 mount_nfs`：rsize 需为 4096 的倍数，readahead 范围 0~128。
NFS_OPTS="nolock,vers=3,rsize=1048576,wsize=1048576,readahead=8"

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

    mount_line="$(mount | grep -F " on ${mount_point} " || true)"
    if [ -n "${mount_line}" ]; then
        if [[ "${mount_line}" == "${SERVER}:"* ]]; then
            probe_error="$(ls -A "${mount_point}" 2>&1 >/dev/null)" && probe_status=0 || probe_status=$?
            if [ "${probe_status}" -eq 0 ]; then
                echo "跳过 ${mount_point}（已挂载）"
                continue
            elif [[ "${probe_error}" == *"Stale NFS file handle"* ]]; then
                echo "${mount_point} 存在失效的 NFS 挂载，正在强制卸载..."
                if ! sudo umount -f "${mount_point}"; then
                    echo "无法清理失效挂载：${mount_point}" >&2
                    exit 1
                fi
            else
                echo "无法检查现有挂载 ${mount_point}：${probe_error}" >&2
                exit 1
            fi
        else
            echo "跳过 ${mount_point}（已由其他来源挂载）"
            continue
        fi
    fi

    # 创建挂载点目录
    sudo mkdir -p "${mount_point}"

    # 挂载（nolock 必须，因为 WinNFSd 不实现 NLM 文件锁）
    sudo mount -t nfs -o "${NFS_OPTS}" "${SERVER}${export_path}" "${mount_point}"

    echo "已挂载 ${SERVER}${export_path} -> ${mount_point}"
done

echo
echo "挂载完成，当前 NFS 挂载情况："
mount | grep " on ${MOUNT_ROOT}/nfs_" || echo "（无）"