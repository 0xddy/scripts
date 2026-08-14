#!/bin/bash

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行此脚本 (例如: sudo bash $0)"
  exit 1
fi

echo "==================================================="
echo "    DMIT VPS (Debian) 启用 root 密码登录脚本"
echo "==================================================="

# 1. 备份原有配置
echo "[1/3] 备份 SSH 配置文件..."
cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M)"

# 2. 修改 SSH 主配置
echo "[2/3] 正在修改 SSH 权限配置..."
# 开启密码登录
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/g' /etc/ssh/sshd_config
# 允许 root 登录
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config

# 如果主配置中根本没有 PermitRootLogin 这一行，则在末尾追加
if ! grep -q "^PermitRootLogin yes" /etc/ssh/sshd_config; then
    echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
fi

# 解决 DMIT cloud-init 覆盖问题
if [ -d /etc/ssh/sshd_config.d ]; then
    for conf in /etc/ssh/sshd_config.d/*.conf; do
        if [ -f "$conf" ]; then
            sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' "$conf"
            sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g' "$conf"
        fi
    done
fi

# 3. 重启 SSH 服务
echo "[3/3] 正在重启 SSH 服务..."
if systemctl restart ssh; then
    echo "==================================================="
    echo "✅ 配置已生效！"
    echo "⚠️ 极其重要：请千万【不要关闭】当前终端窗口！"
    echo "👉 请立即打开一个新的终端，测试使用 root 密码能否成功登录。"
    echo "==================================================="
else
    echo "❌ SSH 服务重启失败，请检查配置文件格式。"
fi
