#!/bin/bash

# --- 配置变量 ---
# Kubernetes 命名空间
NAMESPACE="gitlab-system"
# PostgreSQL Deployment 的名称
DEPLOYMENT_NAME="postgres-gitlab-deployment"
# 备份命令
PG_DUMP_COMMAND="pg_dump -U gitlab -d gitlabhq_production -F c -b -v -f /tmp/backup.dump"
# 远程 Pod 内的临时备份文件路径
REMOTE_FILE_PATH="/tmp/backup.dump"
# 本地下载路径 (指定为当前目录下的 postgre_backups 文件夹)
LOCAL_DOWNLOAD_PATH="./postgre_backups"

# 生成一个基于当前时间的唯一文件名
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOCAL_FILE_NAME="postgres_backup_${TIMESTAMP}.dump"

# --- 辅助函数：检查命令执行状态 ---
check_status() {
    if [ $? -ne 0 ]; then
        echo "❌ 错误: $1"
        # 尝试清理远程文件，以防备份中途失败
        if [ -n "$POD_NAME" ]; then
            kubectl exec -n "$NAMESPACE" "$POD_NAME" -- rm -f "$REMOTE_FILE_PATH" > /dev/null 2>&1
            echo "已尝试清理远程临时文件: $REMOTE_FILE_PATH"
        fi
        exit 1
    fi
}

echo "🚀 开始 PostgreSQL 自动备份与下载过程..."

# 1. 创建本地下载目录
# ----------------------------------------
echo "📁 步骤 1/5: 创建本地下载目录: $LOCAL_DOWNLOAD_PATH..."
if [ ! -d "$LOCAL_DOWNLOAD_PATH" ]; then
    mkdir -p "$LOCAL_DOWNLOAD_PATH"
    echo "已创建本地下载目录。"
fi
# ----------------------------------------

# 2. 自动获取 Pod 名称
# ----------------------------------------
echo "🔍 步骤 2/5: 正在查找 Deployment ($DEPLOYMENT_NAME) 对应的 Pod..."
# 尝试通过 Deployment 名称前缀查找 Pod 名称
POD_NAME=$(kubectl get pods -n "$NAMESPACE" | grep "^$DEPLOYMENT_NAME" | head -n 1 | awk '{print $1}')

if [ -z "$POD_NAME" ]; then
    echo "❌ 错误: 未能在命名空间 $NAMESPACE 中找到名称前缀为 $DEPLOYMENT_NAME 的运行中 Pod。"
    exit 1
fi
echo "✅ 自动找到的 Pod 名称: $POD_NAME"
# ----------------------------------------

# 3. 在 Pod 内执行 pg_dump 备份
# ----------------------------------------
echo "⏳ 步骤 3/5: 正在 Pod ($POD_NAME) 内执行 pg_dump 备份..."

# 先清理一下远程的临时文件，以防上次失败
kubectl exec -n "$NAMESPACE" "$POD_NAME" -- rm -f "$REMOTE_FILE_PATH" > /dev/null 2>&1

# 执行备份命令
kubectl exec -it -n "$NAMESPACE" "$POD_NAME" -- bash -c "$PG_DUMP_COMMAND"
check_status "执行 pg_dump 备份命令失败。请检查 Pod 是否正常，以及数据库用户和名称是否正确。"
echo "✅ 备份执行完成，远程文件路径: $REMOTE_FILE_PATH"
# ----------------------------------------

# 4. 下载备份文件到本地指定路径
# ----------------------------------------
LOCAL_FILE_PATH="${LOCAL_DOWNLOAD_PATH}/${LOCAL_FILE_NAME}"

echo "⬇️ 步骤 4/5: 从 Pod 下载文件到本地路径: $LOCAL_FILE_PATH..."
# 使用 kubectl cp 将文件从 Pod 复制到本地
kubectl cp -n "$NAMESPACE" "$POD_NAME":"$REMOTE_FILE_PATH" "$LOCAL_FILE_PATH"
check_status "下载备份文件失败。"
echo "✅ 下载完成，本地文件路径: $LOCAL_FILE_PATH"
# ----------------------------------------

# 5. 清理 Pod 上的临时文件
# ----------------------------------------
echo "🧹 步骤 5/5: 清理 Pod 上的临时备份文件 $REMOTE_FILE_PATH..."
kubectl exec -it -n "$NAMESPACE" "$POD_NAME" -- rm -f "$REMOTE_FILE_PATH"
check_status "清理远程临时文件失败。"
echo "✅ 远程临时文件清理完成。"
# ----------------------------------------

echo ""
echo "🎉 **所有操作成功完成！**"
echo "最新 PostgreSQL 备份已下载到本地: $LOCAL_FILE_PATH"