#!/bin/bash

# 检查环境类型
if command -v k3s &>/dev/null || systemctl status k3s &>/dev/null; then
  ENV="k3s"
  CERTS_DIR="/var/lib/rancher/k3s/agent/etc/containerd/certs.d"
elif command -v kubelet &>/dev/null; then
  ENV="k8s"
  CERTS_DIR="/etc/containerd/certs.d"
else
  echo "❌ 无法识别 Kubernetes 环境（既不是 k3s，也不是标准 kubelet）"
  exit 1
fi

echo "✅ 检测到环境类型：$ENV"
echo "📝 镜像代理配置目录：$CERTS_DIR"

# 镜像代理主机 IP
MIRROR_IP="192.168.100.10"

# registry => 端口映射
declare -A REGISTRY_PORTS=(
  [docker.io]=51000
  [ghcr.io]=52000
  [gcr.io]=53000
  [k8s.gcr.io]=54000
  [registry.k8s.io]=55000
  [quay.io]=56000
  [mcr.microsoft.com]=57000
  [docker.elastic.co]=58000
  [nvcr.io]=59000
)

# 是否强制覆盖（可选参数）
FORCE=false
if [[ "$1" == "--force" ]]; then
  FORCE=true
  echo "⚠️ 启用强制覆盖模式"
fi

# 遍历并生成 hosts.toml
for REGISTRY in "${!REGISTRY_PORTS[@]}"; do
  PORT=${REGISTRY_PORTS[$REGISTRY]}
  MIRROR_URL="http://${MIRROR_IP}:${PORT}"
  DIR="${CERTS_DIR}/${REGISTRY}"
  FILE="${DIR}/hosts.toml"

  sudo mkdir -p "$DIR"

  CONTENT=$(cat <<EOF
server = "https://${REGISTRY}"

[host."${MIRROR_URL}"]
  capabilities = ["pull", "resolve"]
EOF
)

  if [[ -f "$FILE" && "$FORCE" == false ]]; then
    CURRENT=$(sudo cat "$FILE")
    if [[ "$CURRENT" == "$CONTENT" ]]; then
      echo "✅ 已存在且相同: $FILE，跳过"
      continue
    else
      echo "⚠️ 文件已存在但内容不同: $FILE，使用 --force 参数可覆盖"
      continue
    fi
  fi

  echo "$CONTENT" | sudo tee "$FILE" > /dev/null
  echo "✅ 写入完成: $FILE"
done

# 提示用户是否需要重启服务
if [[ "$ENV" == "k3s" ]]; then
  echo "✅ 配置完成。请重启 K3s：sudo systemctl restart k3s"
else
  echo "✅ 配置完成。请重启 containerd：sudo systemctl restart containerd"
fi

