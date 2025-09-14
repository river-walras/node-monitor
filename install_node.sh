#!/bin/bash
# 改进版的 Node Exporter 安装脚本 + 用户名密码认证

# 检查是否已安装
if systemctl is-active --quiet node_exporter; then
    echo "Node Exporter already running"
    
    # 如果已运行，询问是否添加认证
    read -p "Node Exporter 已运行，是否要添加用户名密码认证？(y/n): " add_auth
    if [[ $add_auth == "y" || $add_auth == "Y" ]]; then
        echo "正在添加认证配置..."
    else
        exit 0
    fi
else
    # 创建专用用户（更安全）
    sudo useradd --no-create-home --shell /bin/false node_exporter

    # 下载并安装
    cd /tmp
    wget https://github.com/prometheus/node_exporter/releases/download/v1.9.1/node_exporter-1.9.1.linux-amd64.tar.gz
    tar xvfz node_exporter-1.9.1.linux-amd64.tar.gz
    sudo cp node_exporter-1.9.1.linux-amd64/node_exporter /usr/local/bin/
    sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter

    # 创建基础系统服务（先不启动）
    sudo tee /etc/systemd/system/node_exporter.service > /dev/null <<EOF
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    echo "✅ Node Exporter 安装完成"
fi

# 询问是否添加认证
read -p "是否要添加用户名密码认证？(y/n，推荐选择 y): " enable_auth

if [[ $enable_auth == "y" || $enable_auth == "Y" ]]; then
    echo "正在配置用户名密码认证..."
    
    # 检查是否安装了 apache2-utils (提供 htpasswd 命令)
    if ! command -v htpasswd &> /dev/null; then
        echo "正在安装 apache2-utils..."
        sudo apt update && sudo apt install -y apache2-utils
    fi

    # 获取用户名和密码
    read -p "请输入用户名 (默认: prometheus): " USERNAME
    USERNAME=${USERNAME:-prometheus}

    read -s -p "请输入密码 (留空自动生成): " PASSWORD
    echo
    if [ -z "$PASSWORD" ]; then
        # 如果没有输入密码，生成一个随机密码
        PASSWORD=$(openssl rand -base64 16)
        echo "已生成随机密码: $PASSWORD"
    fi

    # 创建配置目录
    sudo mkdir -p /etc/node_exporter

    # 生成密码哈希 (使用 bcrypt，Node Exporter 支持)
    HASH=$(echo -n "$PASSWORD" | htpasswd -nBi "$USERNAME" | cut -d: -f2)

    # 创建认证配置文件
    sudo tee /etc/node_exporter/web-config.yml > /dev/null <<EOF
basic_auth_users:
  $USERNAME: '$HASH'
EOF

    # 设置文件权限
    sudo chown node_exporter:node_exporter /etc/node_exporter/web-config.yml
    sudo chmod 600 /etc/node_exporter/web-config.yml

    # 更新 systemd 服务配置以支持认证
    sudo tee /etc/systemd/system/node_exporter.service > /dev/null <<EOF
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter --web.config.file=/etc/node_exporter/web-config.yml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    # 保存认证信息到文件
    echo "username: $USERNAME" | sudo tee /etc/node_exporter/auth_info.txt > /dev/null
    echo "password: $PASSWORD" | sudo tee -a /etc/node_exporter/auth_info.txt > /dev/null
    sudo chmod 600 /etc/node_exporter/auth_info.txt

    echo "✅ 认证配置已添加"
    echo ""
    echo "认证信息:"
    echo "用户名: $USERNAME"
    echo "密码: $PASSWORD"
    echo "📝 认证信息已保存到: /etc/node_exporter/auth_info.txt"
fi

# 启动服务
sudo systemctl daemon-reload
sudo systemctl enable node_exporter
sudo systemctl start node_exporter

# 验证安装
sleep 2
if systemctl is-active --quiet node_exporter; then
    echo "✅ Node Exporter 运行成功"
    systemctl status node_exporter --no-pager -l
    
    # 根据是否启用认证显示不同的测试命令
    if [[ $enable_auth == "y" || $enable_auth == "Y" ]]; then
        echo ""
        echo "测试访问 (需要认证):"
        echo "curl -u $USERNAME:$PASSWORD http://localhost:9100/metrics"
        
        # 测试认证是否工作
        if curl -u "$USERNAME:$PASSWORD" -s http://localhost:9100/metrics > /dev/null; then
            echo "✅ 认证配置正常"
        else
            echo "❌ 认证配置可能有问题"
        fi
    else
        echo ""
        echo "测试访问 (无认证):"
        echo "curl http://localhost:9100/metrics"
        
        if curl -s http://localhost:9100/metrics > /dev/null; then
            echo "✅ Node Exporter 访问正常"
        else
            echo "❌ Node Exporter 访问异常"
        fi
    fi
else
    echo "❌ Node Exporter 启动失败"
    echo "查看日志:"
    sudo journalctl -u node_exporter --no-pager -n 10
    exit 1
fi