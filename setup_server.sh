#!/bin/bash

# 定义颜色输出
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 检查是否以 root/sudo 运行
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 sudo 运行此脚本: sudo ./setup_server.sh${NC}"
  exit 1
fi

# 获取实际登录的用户 (用于配置 SSH key，而不是配置给 root)
REAL_USER=${SUDO_USER:-$(whoami)}
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
PUB_KEY_FILE="./id_ed25519.pub"

echo -e "${GREEN}=== Ubuntu 24.04 Server 一键初始化配置 ===${NC}"
echo -e "当前操作用户: ${YELLOW}$REAL_USER${NC}"

# ==========================================
# 1. 检查 SSH 公钥文件
# ==========================================
if [ ! -f "$PUB_KEY_FILE" ]; then
    echo -e "${RED}错误: 未在当前目录找到 $PUB_KEY_FILE${NC}"
    echo "请上传公钥文件后再运行脚本。"
    exit 1
fi
echo -e "${GREEN}[Check] 公钥文件存在，准备配置...${NC}"

# ==========================================
# 2. 网络配置 (Netplan)
# ==========================================
echo -e "\n${YELLOW}--- 配置静态 IP ---${NC}"

# 列出可用网卡
echo "可用网卡列表:"
ip -o link show | awk -F': ' '{print $2}' | grep -v "lo"
echo ""

read -p "请输入要配置的网卡名称 (例如 ens16f0): " IFACE
# 简单的检查网卡是否存在
if ! ip link show "$IFACE" > /dev/null 2>&1; then
    echo -e "${RED}错误: 网卡 $IFACE 不存在${NC}"
    exit 1
fi

read -p "请输入 IP 地址 (CIDR格式, 例如 192.168.110.239/24): " IP_ADDR
read -p "请输入 网关地址 (例如 192.168.110.1): " GATEWAY
read -p "请输入 DNS 地址 (例如 192.168.110.1): " DNS_SERVER

echo -e "${GREEN}正在生成 Netplan 配置...${NC}"

# 备份旧配置
mkdir -p /etc/netplan/backup
mv /etc/netplan/*.yaml /etc/netplan/backup/ 2>/dev/null
echo "已备份旧 Netplan 配置到 /etc/netplan/backup/"

# 生成新配置 (Ubuntu 24.04 推荐使用 routes 替代 gateway4)
NETPLAN_FILE="/etc/netplan/01-static-ip.yaml"
cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  ethernets:
    $IFACE:
      dhcp4: no
      addresses:
        - $IP_ADDR
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses:
          - $DNS_SERVER
EOF

echo -e "${GREEN}新配置已写入 $NETPLAN_FILE${NC}"
cat "$NETPLAN_FILE"

# 应用网络配置
echo -e "${YELLOW}正在应用网络配置 (netplan apply)...${NC}"
netplan apply
if [ $? -eq 0 ]; then
    echo -e "${GREEN}网络配置应用成功!${NC}"
else
    echo -e "${RED}网络配置应用失败，请检查配置文件格式。${NC}"
    # 可以在这里选择是否退出，暂且继续
fi

# ==========================================
# 3. 配置 SSH 密钥登录
# ==========================================
echo -e "\n${YELLOW}--- 配置 SSH 密钥登录 ---${NC}"

SSH_DIR="$USER_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

# 创建目录
if [ ! -d "$SSH_DIR" ]; then
    mkdir -p "$SSH_DIR"
    echo "创建目录: $SSH_DIR"
fi

# 写入公钥
cat "$PUB_KEY_FILE" >> "$AUTH_KEYS"
echo "公钥已追加到 $AUTH_KEYS"

# 设置正确的权限 (非常重要)
chown -R "$REAL_USER:$REAL_USER" "$SSH_DIR"
chmod 700 "$SSH_DIR"
chmod 600 "$AUTH_KEYS"

echo -e "${GREEN}SSH 密钥配置完成。${NC}"

# ==========================================
# 4. 修改 SSHD 配置 (关闭密码登录)
# ==========================================
echo -e "\n${YELLOW}--- 修改 SSHD 安全配置 ---${NC}"

SSHD_CONFIG="/etc/ssh/sshd_config"
# 备份
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%F_%T)"
echo "已备份 SSHD 配置。"

# 使用 sed 修改配置
# 1. 确保 PubkeyAuthentication yes
if grep -q "^#\?PubkeyAuthentication" "$SSHD_CONFIG"; then
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"
else
    echo "PubkeyAuthentication yes" >> "$SSHD_CONFIG"
fi

# 2. 确保 PasswordAuthentication no
if grep -q "^#\?PasswordAuthentication" "$SSHD_CONFIG"; then
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
else
    echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
fi

# 3. 可选：禁用 ChallengeResponseAuthentication
if grep -q "^#\?ChallengeResponseAuthentication" "$SSHD_CONFIG"; then
    sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSHD_CONFIG"
fi

# 检查 sshd 语法
sshd -t
if [ $? -eq 0 ]; then
    echo -e "${GREEN}SSHD 配置文件语法正确，正在重启 SSH 服务...${NC}"
    systemctl restart ssh
    echo -e "${GREEN}SSH 服务已重启。密码登录已关闭，仅允许密钥登录。${NC}"
else
    echo -e "${RED}SSHD 配置文件语法错误，未重启服务，请检查 $SSHD_CONFIG${NC}"
    exit 1
fi

echo -e "\n${GREEN}=== 所有配置已完成 ===${NC}"
echo -e "当前 IP: $IP_ADDR"
echo -e "请新开一个终端测试 SSH 连接，确保密钥登录正常，不要直接关闭当前会话！"