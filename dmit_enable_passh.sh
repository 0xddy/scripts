#!/bin/bash

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行此脚本 (例如: sudo bash $0)"
  exit 1
fi

echo "==================================================="
echo "    DMIT VPS (Debian) 启用 root 密码登录脚本"
echo "==================================================="

# 1. 强制重置 root 密码（安全第一，防止因为不知道默认密码被锁死）
echo -e "\n[1/4] 请先为 root 账户设置一个新的强密码："
passwd root
if [ $? -ne 0 ]; then
    echo "❌ 密码设置失败，脚本已自动终止，以防止您被锁在服务器外部。"
    exit 1
fi

# 2. 备份原有配置
echo -e "\n[2/4] 备份 SSH 配置文件..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M)

# 3. 修改 SSH 主配置
echo "[3/4] 正在修改 SSH 权限配置..."
# 开启密码登录
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/g' /etc/ssh/sshd_config
# 允许 root 登录
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config

# 如果主配置中根本没有 PermitRootLogin 这一行，则在末尾追加
if ! grep -q "^PermitRootLogin yes" /etc/ssh/sshd_config; then
    echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
fi

# 4. 解决 DMIT cloud-init 覆盖问题
if [ -d /etc/ssh/sshd_config.d ]; then
    for conf in /etc/ssh/sshd_config.d/*.conf; do
        if [ -f "$conf" ]; then
            sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' "$conf"
            sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g' "$conf"
        fi
    done
fi

# 5. 重启 SSH 服务
echo "[4/4] 正在重启 SSH 服务..."
if systemctl restart ssh; then
    echo "==================================================="
    echo "✅ 配置已生效！"
    echo "⚠️ 极其重要：请千万【不要关闭】当前终端窗口！"
    echo "👉 请立即打开一个新的终端或 SSH 客户端，测试使用 root 和新密码登录机器。"
    echo "   确认新窗口可以成功登录后，再关闭当前窗口。"
    echo "==================================================="
else
    echo "❌ SSH 服务重启失败，请检查。"
fi
