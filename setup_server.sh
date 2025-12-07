#!/bin/bash

# ================= 配置区域 =================
# 定义颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 本地生成的临时配置文件名
LOCAL_NETPLAN_FILE="./50-cloud-init.yaml"
# 系统目标路径
SYS_NETPLAN_FILE="/etc/netplan/50-cloud-init.yaml"
# 公钥文件名
PUB_KEY_FILE="./id_ed25519.pub"
# ===========================================

# 检查是否以 sudo 运行
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 sudo 运行此脚本: sudo ./setup_server_final.sh${NC}"
  exit 1
fi

# 获取真实用户（避免配置给 root）
REAL_USER=${SUDO_USER:-$(whoami)}
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# 辅助函数：询问 Yes/No
ask_yes_no() {
    while true; do
        read -p "$1 [y/n]: " yn
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "请输入 y 或 n.";;
        esac
    done
}

# ***** 核心转换函数：子网掩码 (255.255.255.0) 转换为 CIDR (/24) *****
mask_to_cidr() {
    local mask=$1
    local cidr=0
    # 使用 bc 和 tr 将点分十进制转换为二进制并计数 '1'
    for octet in $(echo $mask | tr '.' ' '); do
        # 必须确保 bc 可用
        if ! command -v bc &> /dev/null; then
            echo "BC_MISSING"
            return
        fi

        # 转换为二进制并去除 leading 0s
        # 注意: 某些 bc 版本可能需要更复杂的填充
        binary_octet=$(echo "obase=2;$octet" | bc)

        # 确保每个八位字节都有 8 位，并统计 '1' 的数量
        # 简单地统计字符串中的 '1's
        # 确保掩码是连续的 1，不连续的掩码会被计入但配置 Netplan 会失败，这里只做格式转换。
        ones=$(echo "$binary_octet" | tr -d '0' | wc -c)
        cidr=$((cidr + ones))
    done

    # 简单的有效性检查 (掩码长度在 8 到 32 之间)
    if [[ $cidr -lt 8 || $cidr -gt 32 ]]; then
        echo "ERROR"
    else
        echo "/$cidr"
    fi
}
# *******************************************************************

echo -e "${GREEN}=== Ubuntu 24.04 Server 初始化脚本 (最终修复版) ===${NC}"
echo -e "当前操作目标用户: ${YELLOW}$REAL_USER${NC}"

# ------------------------------------------------------------------
# 1. 网络配置 (Netplan)
# ------------------------------------------------------------------
echo -e "\n${BLUE}### 步骤 1: 网络配置 ###${NC}"

# 显示网卡和当前 IP
echo -e "当前网卡及 IP 信息:"
echo -e "${YELLOW}--------------------------------------------------${NC}"
ip -c -br addr show | grep -v "lo"
echo -e "${YELLOW}--------------------------------------------------${NC}"

# 收集信息
read -p "请输入要配置的网卡名称 (如 enp1s0): " IFACE
if ! ip link show "$IFACE" > /dev/null 2>&1; then
    echo -e "${RED}错误: 网卡 $IFACE 不存在，脚本退出。${NC}"
    exit 1
fi

read -p "请输入 IP 地址 (不含掩码, 如 192.168.100.10): " IP_ONLY
read -p "请输入 子网掩码 (默认 255.255.255.0, 可直接回车): " SUBNET_MASK
read -p "请输入 网关 IP (如 192.168.100.1): " GATEWAY
read -p "请输入 DNS (如 192.168.100.1): " DNS_SERVER

# 默认掩码处理
if [ -z "$SUBNET_MASK" ]; then
    SUBNET_MASK="255.255.255.0"
    echo -e "${YELLOW}使用默认子网掩码: $SUBNET_MASK${NC}"
fi

# 转换掩码
CIDR_PREFIX=$(mask_to_cidr "$SUBNET_MASK")

if [ "$CIDR_PREFIX" == "ERROR" ]; then
    echo -e "${RED}错误: 子网掩码格式 '$SUBNET_MASK' 无效或无法转换。请检查输入。${NC}"
    exit 1
fi
if [ "$CIDR_PREFIX" == "BC_MISSING" ]; then
    echo -e "${RED}错误: 缺少 'bc' 命令，无法进行子网掩码转换。请安装 bc (sudo apt install bc) 或手动输入 CIDR 格式。${NC}"
    exit 1
fi

FINAL_IP_ADDR="${IP_ONLY}${CIDR_PREFIX}"
echo -e "${GREEN}Netplan 使用的最终 IP 地址格式: $FINAL_IP_ADDR${NC}"

# 在当前目录生成配置文件
echo -e "\n正在当前目录生成 ${LOCAL_NETPLAN_FILE} ..."
cat > "$LOCAL_NETPLAN_FILE" <<EOF
network:
  version: 2
  ethernets:
    $IFACE:
      dhcp4: no
      addresses:
        - $FINAL_IP_ADDR
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses:
          - $DNS_SERVER
EOF

echo -e "${GREEN}配置已生成，内容如下:${NC}"
echo -e "${YELLOW}--------------------------------------------------${NC}"
cat "$LOCAL_NETPLAN_FILE"
echo -e "${YELLOW}--------------------------------------------------${NC}"

# 询问是否替换系统配置
if ask_yes_no "是否要用此文件替换系统的 $SYS_NETPLAN_FILE 并应用网络配置?"; then
    # 备份
    if [ -f "$SYS_NETPLAN_FILE" ]; then
        mkdir -p /etc/netplan/backup
        cp "$SYS_NETPLAN_FILE" "/etc/netplan/backup/50-cloud-init.yaml.bak.$(date +%s)"
        echo "已备份原配置到 /etc/netplan/backup/"
    fi

    # 替换
    cp "$LOCAL_NETPLAN_FILE" "$SYS_NETPLAN_FILE"
    chmod 600 "$SYS_NETPLAN_FILE"

    echo -e "正在应用 Netplan 配置..."
    netplan apply
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}网络配置应用成功!${NC}"
    else
        echo -e "${RED}警告: netplan apply 失败，请检查配置。${NC}"
    fi
else
    echo "跳过网络配置应用。"
fi

# ------------------------------------------------------------------
# 2. SSH 密钥配置
# ------------------------------------------------------------------
echo -e "\n${BLUE}### 步骤 2: SSH 密钥配置 ###${NC}"

if [ -f "$PUB_KEY_FILE" ]; then
    echo -e "发现公钥文件: ${YELLOW}$PUB_KEY_FILE${NC}"
    if ask_yes_no "是否将此公钥写入用户 $REAL_USER 的授权列表?"; then
        SSH_DIR="$USER_HOME/.ssh"
        AUTH_KEYS="$SSH_DIR/authorized_keys"

        mkdir -p "$SSH_DIR"

        if [ -f "$AUTH_KEYS" ]; then
             echo "authorized_keys 文件已存在。"
             read -p "选择操作: [A]追加 (Append) / [O]覆盖 (Overwrite) / [S]跳过: " key_op
             case $key_op in
                [Aa]* )
                    cat "$PUB_KEY_FILE" >> "$AUTH_KEYS"
                    echo -e "${GREEN}公钥已追加。${NC}"
                    ;;
                [Oo]* )
                    cat "$PUB_KEY_FILE" > "$AUTH_KEYS"
                    echo -e "${GREEN}公钥已覆盖旧文件。${NC}"
                    ;;
                * ) echo "跳过密钥写入。" ;;
             esac
        else
            cat "$PUB_KEY_FILE" > "$AUTH_KEYS"
            echo -e "${GREEN}已创建 authorized_keys 并写入公钥。${NC}"
        fi

        # 修复权限
        chown -R "$REAL_USER:$REAL_USER" "$SSH_DIR"
        chmod 700 "$SSH_DIR"
        chmod 600 "$AUTH_KEYS"
    fi
else
    echo -e "${YELLOW}未在当前目录找到 $PUB_KEY_FILE，跳过密钥导入。${NC}"
fi

# ------------------------------------------------------------------
# 3. SSHD 服务配置 (交互式)
# ------------------------------------------------------------------
echo -e "\n${BLUE}### 步骤 3: SSH 服务安全设置 ###${NC}"
SSHD_CONFIG="/etc/ssh/sshd_config"
NEED_RESTART=0

# 询问是否开启 SSH 服务
if ask_yes_no "是否确保 SSH 服务已开启并设置为开机自启?"; then
    systemctl enable ssh
    systemctl start ssh
    echo -e "${GREEN}SSH 服务已启用。${NC}"
fi

# 备份配置文件
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%F_%T)"

# 询问是否开启 密钥登录
if ask_yes_no "是否允许 SSH 密钥登录 (PubkeyAuthentication)?"; then
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"
    echo " -> 已设置: PubkeyAuthentication yes"
    NEED_RESTART=1
else
    if ask_yes_no "  -> 是否要显式关闭密钥登录?"; then
        sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication no/' "$SSHD_CONFIG"
        echo " -> 已设置: PubkeyAuthentication no"
        NEED_RESTART=1
    fi
fi

# 询问是否开启 密码登录
if ask_yes_no "是否允许 SSH 密码登录 (PasswordAuthentication)?"; then
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_CONFIG"
    echo " -> 已设置: PasswordAuthentication yes"
    NEED_RESTART=1
else
    echo -e "${YELLOW}正在关闭密码登录...${NC}"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
    echo " -> 已设置: PasswordAuthentication no"
    NEED_RESTART=1
fi

# 应用更改
if [ $NEED_RESTART -eq 1 ]; then
    echo -e "\n正在检查 SSHD 配置语法..."
    sshd -t
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}语法检查通过，正在重启 SSH 服务...${NC}"
        systemctl restart ssh
        echo -e "${GREEN}SSH 配置已更新。${NC}"
    else
        echo -e "${RED}错误: SSHD 配置文件语法有误，未重启服务。请检查备份文件。${NC}"
    fi
else
    echo "SSH 配置未发生变更。"
fi

echo -e "\n${GREEN}=== 所有配置操作已完成 ===${NC}"