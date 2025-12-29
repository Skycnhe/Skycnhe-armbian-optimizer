# Armbian/Debian 一键优化脚本

适用于 Armbian、Ubuntu、Debian 的综合优化工具。

## 功能
- 🇨🇳 **本地化**: 自动设置 `Asia/Shanghai` 时区与 `zh_CN` 中文环境。
- 🚀 **网络**: 开启 TCP BBR，支持交互式配置静态 IP。
- 📦 **软件源**: 自动更换清华大学镜像源。
- 🐳 **Docker**: 一键安装 Docker 并配置国内镜像加速与日志限制。
- 💾 **寿命**: 安装 Log2Ram，延长 SD 卡使用寿命。

## 食用方法 (一键安装)

**确保已连接网络，在终端执行以下命令：**

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Skycnhe/Skycnhe-armbian-optimizer/refs/heads/main/optimize.sh)"

N1特别优化


sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Skycnhe/Skycnhe-armbian-optimizer/refs/heads/main/N1.sh)"
