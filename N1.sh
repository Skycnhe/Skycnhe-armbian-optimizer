#!/bin/bash

# ==============================================================================
# 斐讯 N1 (Phicomm N1) Armbian 专属优化脚本 v6.0
# 功能：换源 | 静态IP | BBR | Docker | Log2Ram | N1硬件修正 | TUN/IP转发
# 更新：v6.0 新增 TUN 开启与 IP Forwarding (旁路由/VPN必备)
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
echo -e "${SKYBLUE}       斐讯 N1 深度优化脚本 v6.0 (Pro)          ${PLAIN}"
echo -e "${SKYBLUE}================================================${PLAIN}"
echo -e "${YELLOW}机型: $(cat /proc/device-tree/model 2>/dev/null || echo 'N1/Armbian Box')${PLAIN}"
echo ""

# ---------------- 通用功能函数 ----------------

function set_timezone() {
    echo -e "${GREEN}[*] 设置时区为 Asia/Shanghai ...${PLAIN}"
    timedatectl set-timezone Asia/Shanghai
    timedatectl set-ntp true
    echo -e "${GREEN}[√] 时区已设置。${PLAIN}"
}

function set_language_cn() {
    echo -e "${GREEN}[*] 配置中文环境...${PLAIN}"
    if ! grep -q "zh_CN.UTF-8" /etc/locale.gen; then
        apt-get update && apt-get install -y locales
    fi
    sed -i 's/^# *zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen
    update-locale LANG=zh_CN.UTF-8
    echo -e "${GREEN}[√] 中文环境已配置 (重启生效)。${PLAIN}"
}

function set_static_ip() {
    echo -e "${YELLOW}>>> 警告：修改 IP 可能导致 SSH 断开！<<<${PLAIN}"
    if ! command -v nmcli &> /dev/null; then echo -e "${RED}错误：未找到 nmcli。${PLAIN}"; return; fi
    
    DEFAULT_DEV=$(ip route | grep default | awk '{print $5}' | head -n1)
    read -p "输入网卡名称 (默认 $DEFAULT_DEV): " CON_NAME
    CON_NAME=${CON_NAME:-$DEFAULT_DEV}
    read -p "输入 IP (例 192.168.1.10/24): " IP_ADDR
    read -p "输入网关 (例 192.168.1.1): " GW_ADDR
    
    if [[ -z "$IP_ADDR" || -z "$GW_ADDR" ]]; then echo "参数不完整"; return; fi
    
    nmcli connection modify "$CON_NAME" ipv4.addresses "$IP_ADDR" ipv4.gateway "$GW_ADDR" ipv4.dns "223.5.5.5 114.114.114.114" ipv4.method manual
    echo -e "${GREEN}[√] IP 配置已保存 (需重启网络)。${PLAIN}"
}

function enable_bbr() {
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1
    echo -e "${GREEN}[√] BBR 已开启。${PLAIN}"
}

function change_mirrors() {
    cp /etc/apt/sources.list /etc/apt/sources.list.bak
    sed -i 's|http://ports.ubuntu.com/|https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/|g' /etc/apt/sources.list
    sed -i 's|http://archive.ubuntu.com/|https://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' /etc/apt/sources.list
    sed -i 's|http://deb.debian.org/debian|https://mirrors.tuna.tsinghua.edu.cn/debian|g' /etc/apt/sources.list
    apt update
    echo -e "${GREEN}[√] 换源完成。${PLAIN}"
}

function install_docker() {
    if ! command -v docker &> /dev/null; then
        curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun
    fi
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": ["https://docker.m.daocloud.io", "https://docker.1panel.live"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "2" }
}
EOF
    systemctl daemon-reload && systemctl restart docker
    echo -e "${GREEN}[√] Docker 安装及优化完成。${PLAIN}"
}

function install_log2ram() {
    echo "deb [signed-by=/usr/share/keyrings/azlux-archive-keyring.gpg] http://packages.azlux.fr/debian/ bookworm main" | tee /etc/apt/sources.list.d/azlux.list
    wget -O /usr/share/keyrings/azlux-archive-keyring.gpg  https://azlux.fr/repo.gpg
    apt update && apt install -y log2ram
    sed -i 's/SIZE=40M/SIZE=128M/g' /etc/log2ram.conf
    echo -e "${GREEN}[√] Log2Ram 已安装。${PLAIN}"
}

# ---------------- N1 专属与网络高级功能 ----------------

# 8. 开启 TUN 与 IP 转发 (新增核心功能)
function enable_tun_forward() {
    echo -e "${GREEN}[*] 正在配置 TUN 设备与 IP 转发...${PLAIN}"
    
    # 1. 开启 IP Forwarding (旁路由/网关必备)
    sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1
    echo -e "   - IP 转发已开启"

    # 2. 加载 TUN 模块
    modprobe tun
    if ! grep -q "^tun$" /etc/modules; then
        echo "tun" >> /etc/modules
    fi
    
    # 3. 检查并创建设备节点 (防止 /dev/net/tun 缺失)
    if [ ! -e /dev/net/tun ]; then
        echo -e "   - 创建 /dev/net/tun 节点..."
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200
        chmod 666 /dev/net/tun
    fi

    # 验证
    if lsmod | grep -q tun; then
        echo -e "${GREEN}[√] TUN 模块已加载，开机自启已配置。${PLAIN}"
    else
        echo -e "${RED}[!] TUN 模块加载失败，请检查固件内核是否支持。${PLAIN}"
    fi
}

# 9. N1 硬件修正
function optimize_n1_hardware() {
    echo -e "${GREEN}[*] 执行 N1 硬件优化...${PLAIN}"
    # 禁用蓝牙WiFi
    systemctl stop bluetooth hciuart wpa_supplicant >/dev/null 2>&1
    systemctl disable bluetooth hciuart wpa_supplicant >/dev/null 2>&1
    
    # 固定MAC
    CURRENT_MAC=$(cat /sys/class/net/eth0/address)
    if [[ -n "$CURRENT_MAC" ]] && command -v nmcli &> /dev/null; then
        CON_NAME=$(nmcli -t -f NAME,DEVICE connection show --active | grep :eth0 | cut -d: -f1 | head -n1)
        if [[ -n "$CON_NAME" ]]; then
            nmcli connection modify "$CON_NAME" ethernet.cloned-mac-address "$CURRENT_MAC"
            echo -e "   - MAC 地址锁定成功"
        fi
    fi
    
    # 关灯
    if [[ -d /sys/class/leds/onecloud:white:alive ]]; then
        echo none > /sys/class/leds/onecloud:white:alive/trigger
    fi
    echo -e "${GREEN}[√] 硬件优化完成。${PLAIN}"
}

# 10. 禁用无用服务
function disable_bloatware() {
    SERVICES=("ModemManager" "cups" "cups-browsed" "avahi-daemon" "multipath-tools" "snapd")
    for svc in "${SERVICES[@]}"; do
        systemctl disable --now "$svc" >/dev/null 2>&1
    done
    echo -e "${GREEN}[√] 无用服务已禁用。${PLAIN}"
}

# 11. 系统清理
function clean_system() {
    apt-get autoremove -y && apt-get clean
    rm -rf /var/lib/apt/lists/*
    echo -e "${GREEN}[√] 清理完成。$(df -h / | awk 'NR==2 {print "剩余: " $4}')${PLAIN}"
}

# 主菜单
echo "----------------------------------------"
echo " 1. 设置时区 (Asia/Shanghai)"
echo " 2. 设置中文环境 (zh_CN)"
echo " 3. 修改静态 IP"
echo " 4. 开启 BBR 加速"
echo " 5. 更换国内源"
echo " 6. 安装 Docker (N1优化版)"
echo " 7. 安装 Log2Ram (保护eMMC)"
echo " 8. 开启 TUN 模式与 IP 转发 (VPN/旁路由必备)"
echo " 9. N1专属: 固定MAC/关LED/禁蓝牙"
echo " 10. 禁用无用服务 (ModemManager等)"
echo " 11. 磁盘深度清理"
echo " 12. [N1一键全套] 执行 1,2,4,5,7,8,9,10,11"
echo " 0. 退出"
echo "----------------------------------------"
read -p "请输入: " choice

case $choice in
    1) set_timezone ;;
    2) set_language_cn ;;
    3) set_static_ip ;;
    4) enable_bbr ;;
    5) change_mirrors ;;
    6) install_docker ;;
    7) install_log2ram ;;
    8) enable_tun_forward ;;
    9) optimize_n1_hardware ;;
    10) disable_bloatware ;;
    11) clean_system ;;
    12)
        set_timezone
        set_language_cn
        change_mirrors
        enable_bbr
        install_log2ram
        enable_tun_forward
        optimize_n1_hardware
        disable_bloatware
        clean_system
        echo -e "${YELLOW}提示：全套优化完成！建议重启系统。${PLAIN}"
        ;;
    0) exit 0 ;;
    *) echo "无效选择" ;;
esac
