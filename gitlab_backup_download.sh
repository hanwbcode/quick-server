#!/bin/bash

# --- 配置变量 ---
# Kubernetes 命名空间
NAMESPACE="gitlab-system"
# GitLab Deployment 的名称（用于查找 Pod）
DEPLOYMENT_NAME="gitlab-toolbox"
# GitLab 备份文件所在的远程目录
REMOTE_BACKUP_DIR="/srv/gitlab/tmp/backups"
# 默认的本地下载路径 (相对于脚本执行目录)
LOCAL_DOWNLOAD_PATH="./gitlab_backups"

# --- 辅助函数：检查命令执行状态 ---
check_status() {
    if [ $? -ne 0 ]; then
        echo "❌ 错误: $1"
        exit 1
    fi
}

echo "🚀 开始 GitLab 自动备份与下载过程..."

# 1. 创建本地下载目录
# ----------------------------------------
echo "📁 步骤 1/7: 创建本地下载目录..."
if [ ! -d "$LOCAL_DOWNLOAD_PATH" ]; then
    mkdir -p "$LOCAL_DOWNLOAD_PATH"
    echo "已创建本地下载目录: $LOCAL_DOWNLOAD_PATH"
fi
# ----------------------------------------

# 2. 自动获取 Pod 名称
# ----------------------------------------
echo "🔍 步骤 2/7: 正在查找 Deployment ($DEPLOYMENT_NAME) 对应的 Pod..."
# 尝试通过 Deployment 名称前缀查找 Pod 名称
POD_NAME=$(kubectl get pods -n "$NAMESPACE" | grep "^$DEPLOYMENT_NAME" | head -n 1 | awk '{print $1}')

if [ -z "$POD_NAME" ]; then
    echo "❌ 错误: 未能在命名空间 $NAMESPACE 中找到名称前缀为 $DEPLOYMENT_NAME 的运行中 Pod。"
    exit 1
fi
echo "✅ 自动找到的 Pod 名称: $POD_NAME"
# ----------------------------------------

# 3. 在 Pod 内执行备份命令
# ----------------------------------------
echo "⏳ 步骤 3/7: 正在 Pod ($POD_NAME) 内执行 gitlab-backup-cli backup all..."
kubectl exec -it -n "$NAMESPACE" "$POD_NAME" -- gitlab-backup-cli backup all
check_status "执行备份命令失败。"
echo "✅ 备份执行完成。"
# ----------------------------------------

# 4. 查找最新的备份目录名称并压缩
# ----------------------------------------
echo "🔍 步骤 4/7: 查找最新的备份目录并进行压缩..."

# 查找最新的目录名称
LATEST_DIR=$(kubectl exec -it -n "$NAMESPACE" "$POD_NAME" -- bash -c "ls -td $REMOTE_BACKUP_DIR/*/ | head -1 | xargs basename")
check_status "查找最新目录失败。"

if [ -z "$LATEST_DIR" ]; then
    echo "❌ 错误: 在 $REMOTE_BACKUP_DIR 中未找到任何备份目录。"
    exit 1
fi

ARCHIVE_FILENAME="${LATEST_DIR}.tar.gz"
REMOTE_ARCHIVE_PATH="${REMOTE_BACKUP_DIR}/${ARCHIVE_FILENAME}"

echo "📦 找到最新目录: $LATEST_DIR。正在压缩为 $ARCHIVE_FILENAME..."

# 核心修正：使用 sh -c 并将变量值安全地嵌入到远程命令中，避免 Git Bash 路径转换问题
REMOTE_CMD="tar -czf ${REMOTE_ARCHIVE_PATH} -C ${REMOTE_BACKUP_DIR} ${LATEST_DIR}"

kubectl exec -it -n "$NAMESPACE" "$POD_NAME" -- sh -c "${REMOTE_CMD}"
check_status "压缩备份目录失败。"
echo "✅ 压缩完成，远程文件路径: $REMOTE_ARCHIVE_PATH"
# ----------------------------------------

# 5. 下载压缩文件到本地
# ----------------------------------------
LOCAL_FILE_PATH="${LOCAL_DOWNLOAD_PATH}/${ARCHIVE_FILENAME}"

echo "⬇️ 步骤 5/7: 从 Pod 下载 $ARCHIVE_FILENAME 到本地路径 $LOCAL_DOWNLOAD_PATH..."
# 使用 kubectl cp 将文件从 Pod 复制到本地路径
kubectl cp -n "$NAMESPACE" "$POD_NAME":"$REMOTE_ARCHIVE_PATH" "$LOCAL_FILE_PATH"
check_status "下载压缩文件失败。"
echo "✅ 下载完成，本地文件路径: $LOCAL_FILE_PATH"
# ----------------------------------------

# 6. 清理 Pod 上的临时压缩文件
# ----------------------------------------
echo "🧹 步骤 6/7: 清理 Pod 上的临时压缩文件 $REMOTE_ARCHIVE_PATH..."
kubectl exec -it -n "$NAMESPACE" "$POD_NAME" -- rm -f "$REMOTE_ARCHIVE_PATH"
check_status "清理远程压缩文件失败。"
echo "✅ 远程临时压缩文件清理完成。"
# ----------------------------------------

# 7. 清理 Pod 上的未压缩备份目录
# ----------------------------------------
echo "🧹 步骤 7/7: 清理 Pod 上的未压缩备份目录 ${REMOTE_BACKUP_DIR}/${LATEST_DIR}..."
kubectl exec -it -n "$NAMESPACE" "$POD_NAME" -- rm -rf "${REMOTE_BACKUP_DIR}/${LATEST_DIR}"
check_status "清理远程备份目录失败。"
echo "✅ 远程备份目录清理完成。"
# ----------------------------------------

echo ""
echo "🎉 **所有操作成功完成！**"
echo "最新 GitLab 备份已下载到本地相对路径: $LOCAL_FILE_PATH"