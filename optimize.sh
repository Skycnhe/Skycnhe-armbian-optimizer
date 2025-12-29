#!/bin/bash

# ==============================================================================
# Armbian/Debian/Ubuntu 一键综合优化脚本 v3.0
# 功能：换源 | 静态IP | 中文环境 | BBR | Docker加速 | Log2Ram | 时区校正
# 作者：GitHub User
# ==============================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误：请使用 sudo 或 root 权限运行此脚本！${PLAIN}"
    exit 1
fi

# 检查必要命令
if ! command -v curl &> /dev/null; then
    apt-get update && apt-get install -y curl
fi

clear
echo -e "${SKYBLUE}================================================${PLAIN}"
echo -e "${SKYBLUE}       Armbian 深度优化脚本 v3.0 (Pro)          ${PLAIN}"
echo -e "${SKYBLUE}================================================${PLAIN}"
echo -e "${YELLOW}系统时间: $(date)${PLAIN}"
echo ""

# ---------------- 功能函数区 ----------------

# 1. 设置时区 (Asia/Shanghai)
function set_timezone() {
    echo -e "${GREEN}[*] 设置时区为 Asia/Shanghai ...${PLAIN}"
    timedatectl set-timezone Asia/Shanghai
    timedatectl set-ntp true
    echo -e "${GREEN}[√] 时区已设置，时间已同步。${PLAIN}"
}

# 2. 设置中文环境 (zh_CN.UTF-8)
function set_language_cn() {
    echo -e "${GREEN}[*] 配置中文环境...${PLAIN}"
    if ! grep -q "zh_CN.UTF-8" /etc/locale.gen; then
        apt-get update
        apt-get install -y locales
    fi
    sed -i 's/^# *zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen
    update-locale LANG=zh_CN.UTF-8
    update-locale LC_ALL=zh_CN.UTF-8
    echo -e "${GREEN}[√] 中文语言包已生成，请重启后查看效果。${PLAIN}"
}

# 3. 静态 IP 配置 (交互式)
function set_static_ip() {
    echo -e "${YELLOW}>>> 警告：修改 IP 可能导致 SSH 断开，请谨慎操作！<<<${PLAIN}"
    
    if ! command -v nmcli &> /dev/null; then
        echo -e "${RED}错误：未检测到 NetworkManager (nmcli)，无法自动配置 IP。${PLAIN}"
        return
    fi

    echo -e "${SKYBLUE}当前连接列表：${PLAIN}"
    nmcli connection show
    echo "------------------------"
    
    # 获取默认网关的接口名
    DEFAULT_DEV=$(ip route | grep default | awk '{print $5}' | head -n1)
    
    read -p "输入网卡/连接名称 (默认: $DEFAULT_DEV): " CON_NAME
    CON_NAME=${CON_NAME:-$DEFAULT_DEV}

    read -p "输入静态 IP (例: 192.168.1.100/24): " IP_ADDR
    if [[ -z "$IP_ADDR" ]]; then echo -e "${RED}IP 不能为空!${PLAIN}"; return; fi

    read -p "输入网关 (例: 192.168.1.1): " GW_ADDR
    if [[ -z "$GW_ADDR" ]]; then echo -e "${RED}网关不能为空!${PLAIN}"; return; fi

    read -p "输入 DNS (回车默认 223.5.5.5): " DNS_ADDR
    DNS_ADDR=${DNS_ADDR:-"223.5.5.5 114.114.114.114"}

    echo -e "${GREEN}[*] 正在应用静态 IP 配置...${PLAIN}"
    nmcli connection modify "$CON_NAME" ipv4.addresses "$IP_ADDR" ipv4.gateway "$GW_ADDR" ipv4.dns "$DNS_ADDR" ipv4.method manual
    
    echo -e "${GREEN}[√] 配置已保存。${PLAIN}"
    read -p "是否立即重启网络接口? (y/n): " restart_net
    if [[ "$restart_net" == "y" ]]; then
        echo -e "${YELLOW}正在重启网络... 如果 IP 变更，SSH 将断开。${PLAIN}"
        nmcli connection up "$CON_NAME"
    fi
}

# 4. 开启 BBR
function enable_bbr() {
    echo -e "${GREEN}[*] 检测并开启 TCP BBR...${PLAIN}"
    # 清理旧配置
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1
    
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo -e "${GREEN}[√] BBR 已成功开启！${PLAIN}"
    else
        echo -e "${RED}[!] BBR开启失败，可能是内核版本过低。${PLAIN}"
    fi
}

# 5. 更换国内源 (清华源)
function change_mirrors() {
    echo -e "${GREEN}[*] 备份并更换为清华大学软件源...${PLAIN}"
    cp /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%s)
    
    # 智能替换
    sed -i 's|http://ports.ubuntu.com/|https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/|g' /etc/apt/sources.list
    sed -i 's|http://archive.ubuntu.com/|https://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' /etc/apt/sources.list
    sed -i 's|http://security.ubuntu.com/|https://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' /etc/apt/sources.list
    sed -i 's|http://deb.debian.org/debian|https://mirrors.tuna.tsinghua.edu.cn/debian|g' /etc/apt/sources.list
    
    echo -e "${GREEN}[*] 更新软件包列表...${PLAIN}"
    apt update
    echo -e "${GREEN}[√] 换源完成。${PLAIN}"
}

# 6. 安装 Docker及优化
function install_docker() {
    echo -e "${GREEN}[*] 安装/配置 Docker...${PLAIN}"
    if ! command -v docker &> /dev/null; then
        curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun
    fi
    
    mkdir -p /etc/docker
    # 配置镜像加速和日志限制
    cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.1panel.live"
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}
EOF
    systemctl daemon-reload
    systemctl restart docker
    echo -e "${GREEN}[√] Docker 安装及优化完成。${PLAIN}"
}

# 7. 安装 Log2Ram
function install_log2ram() {
    echo -e "${GREEN}[*] 安装 Log2Ram (保护SD卡)...${PLAIN}"
    echo "deb [signed-by=/usr/share/keyrings/azlux-archive-keyring.gpg] http://packages.azlux.fr/debian/ bookworm main" | tee /etc/apt/sources.list.d/azlux.list
    wget -O /usr/share/keyrings/azlux-archive-keyring.gpg  https://azlux.fr/repo.gpg
    apt update
    apt install -y log2ram
    sed -i 's/SIZE=40M/SIZE=128M/g' /etc/log2ram.conf
    echo -e "${GREEN}[√] Log2Ram 安装完成，请重启生效。${PLAIN}"
}

# 8. 更新系统与工具
function update_tools() {
    echo -e "${GREEN}[*] 安装常用工具 (htop, vim, git, wget)...${PLAIN}"
    apt update
    apt install -y curl wget git vim htop net-tools zram-tools
    echo -e "${GREEN}[√] 工具安装完成。${PLAIN}"
}

# 主菜单
echo "请选择要执行的操作："
echo "----------------------------------------"
echo " 1. 设置时区 (Asia/Shanghai)"
echo " 2. 设置中文环境 (zh_CN.UTF-8)"
echo " 3. 修改静态 IP (慎用)"
echo " 4. 开启 BBR 加速"
echo " 5. 更换国内源 (清华源)"
echo " 6. 安装 Docker + 镜像加速"
echo " 7. 安装 Log2Ram"
echo " 8. 安装常用工具"
echo " 9. [一键全自动] 执行 1,2,4,5,7,8 (不含IP和Docker)"
echo " 0. 退出"
echo "----------------------------------------"
read -p "请输入数字 [0-9]: " choice

case $choice in
    1) set_timezone ;;
    2) set_language_cn ;;
    3) set_static_ip ;;
    4) enable_bbr ;;
    5) change_mirrors ;;
    6) install_docker ;;
    7) install_log2ram ;;
    8) update_tools ;;
    9)
        set_timezone
        set_language_cn
        change_mirrors
        update_tools
        enable_bbr
        install_log2ram
        echo -e "${YELLOW}提示：建议手动重启系统 (reboot) 以应用所有更改。${PLAIN}"
        ;;
    0) exit 0 ;;
    *) echo "无效选择" ;;
esac

if [[ "$choice" != "0" ]]; then
    echo ""
    echo -e "${SKYBLUE}脚本执行完毕。部分设置需要重启生效： reboot${PLAIN}"
fi
