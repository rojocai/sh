#!/bin/bash

# Debian 12 完整数据自动备份脚本（RojoHome版 + 智能Rclone检测 + 修复校验版 + 通知功能 + 计划任务 + 网盘备份）
# 备份内容: Docker容器 + 网站数据 + 配置 + 数据库
# 执行时间: 可配置，默认每天凌晨2点
# 备份文件: /backup/debian_backup_年月日_时分秒.tar.gz

# 记录开始时间
START_TIME=$(date +%s)

# 配置参数
BACKUP_BASE="/backup"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="debian_backup_$DATE"
BACKUP_DIR="/tmp/$BACKUP_NAME"
BACKUP_FILE="$BACKUP_BASE/$BACKUP_NAME.tar.gz"
RETENTION_DAYS=7
LOG_FILE="/var/log/auto_backup.log"
CONFIG_FILE="/etc/hostbackup.conf"
CRON_FILE="/etc/cron.d/auto_backup"

# 备份计划参数
BACKUP_HOUR=2
BACKUP_MINUTE=0

# 获取设备名称
HOSTNAME=$(hostname | cut -d'.' -f1)
REMOTE_BACKUP_DIR="${HOSTNAME}_backup"

# 数据库配置
MYSQL_BACKUP_ENABLED=true
POSTGRES_BACKUP_ENABLED=true
MONGODB_BACKUP_ENABLED=true
REDIS_BACKUP_ENABLED=true

# 通知配置
SENDER_EMAIL=""           # 发送邮箱地址
EMAIL_AUTH_CODE=""        # 邮箱授权码
RECEIVER_EMAIL=""         # 接收通知的邮箱地址
TG_BOT_TOKEN=""
TG_CHAT_ID=""
NOTIFICATION_METHOD=""
Backup_notification="0"   # 新增：备份通知方式记录

# 备份方式配置
BACKUP_METHOD=""  # local/remote/cloud/both_remote/both_cloud/all
# 修改：支持多网盘选择，用逗号分隔存储
BACKUP_CLOUD_TYPES=""  # 如 "baidu,google,onedrive"

# Docker镜像备份配置
DOCKER_IMAGE_BACKUP_MODE=""  # none/running/all/list

# Rclone 配置（将在配置过程中设置）
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"

# Rclone 性能参数
RCLONE_TRANSFERS=16
RCLONE_STREAMS=4
RCLONE_BUFFER_SIZE="128M"
RCLONE_CHECKERS=8

# SSH配置
SSH_KEY_DIR="/root/.ssh"
KNOWN_HOSTS_FILE="$SSH_KEY_DIR/known_hosts"

# 邮件配置变量
SMTP_SERVER=""
SMTP_PORT=""

# ByPy百度网盘配置
BYPY_INSTALLED=false
BYPY_CLOUD_DIR="${HOSTNAME}_backup"
BYPY_CONFIG_DIR="$HOME/.bypy"

# 备份状态变量
LOCAL_BACKUP_STATUS=""
declare -A REMOTE_BACKUP_STATUS=()
declare -A CLOUD_BACKUP_STATUS=()

# OneDrive配置变量
ONEDRIVE_CLIENT_ID=""
ONEDRIVE_CLIENT_SECRET=""
ONEDRIVE_ACCESS_TOKEN=""
ONEDRIVE_REFRESH_TOKEN=""
ONEDRIVE_REMOTE_NAME="onedrive"
ONEDRIVE_REMOTE_FOLDER="我的备份"
ONEDRIVE_DRIVE_ID="952e113c33a1a018"  # 默认值
ONEDRIVE_DRIVE_TYPE="personal"        # 默认值

# Google Drive配置变量 - 交互式配置
GDRIVE_REMOTE_NAME="gdrive"

# 创建临时备份目录
mkdir -p $BACKUP_DIR
mkdir -p $BACKUP_BASE
mkdir -p $SSH_KEY_DIR

# 日志函数
log() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" | tee -a $LOG_FILE
}

# 显示Logo
show_logo() {
    echo ""
    echo "=========================================================="
    echo "             ██████╗  ██████╗  ██╗  ██████╗                        "
    echo "             ██╔══██╗██╔═══██╗ ██║ ██╔═══██╗                       "
    echo "             ██████╔╝██║   ██║ ██║ ██║   ██║                       "
    echo "             ██╔══██╗██║   ██║ ██║ ██║   ██║                       "
    echo "             ██║  ██║╚██████╔╝ ██║ ╚██████╔╝                       "
    echo "             ╚═╝  ╚═╝ ╚═════╝  ╚═╝  ╚═════╝                        "
    echo "                                                         "
    echo "              东 白 湖 之 家  备 份 系 统              "
    echo "                 Backup System v1.0                   "
    echo "             个人博客：https://halo.dbhzj.top       "
    echo " 个人导航地址：https://rojohome.cn https://www.dbhzj.com     "
    echo "=========================================================="
    echo "备份时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "备份文件: $BACKUP_NAME"
    echo "设备名称: $HOSTNAME"
    echo "远程目录: $REMOTE_BACKUP_DIR"
    echo "网盘目录: $BYPY_CLOUD_DIR"
    echo "备份计划: 每天 $BACKUP_HOUR:$BACKUP_MINUTE"
    echo "保留天数: $RETENTION_DAYS 天"
    echo "=========================================================="
    echo ""
}

# 计算并显示执行时间
show_execution_time() {
    local end_time=$(date +%s)
    local total_time=$((end_time - START_TIME))
    local hours=$((total_time / 3600))
    local minutes=$(( (total_time % 3600) / 60 ))
    local seconds=$((total_time % 60))
    
    echo ""
    echo "=========================================================="
    echo "                    执行时间统计                          "
    echo "=========================================================="
    printf "总执行时间: %02d小时 %02d分钟 %02d秒\n" $hours $minutes $seconds
    echo "开始时间: $(date -d @$START_TIME '+%Y-%m-%d %H:%M:%S')"
    echo "结束时间: $(date -d @$end_time '+%Y-%m-%d %H:%M:%S')"
    echo "=========================================================="
}

# 从rclone配置读取远程服务器IP地址
get_remote_host() {
    local remote_name="$1"
    
    if [ -f "$RCLONE_CONFIG" ]; then
        # 查找对应远程配置的host字段
        local host=$(awk -v name="$remote_name" '
        /^\['"$remote_name"'\]/ { found=1; next }
        /^\[/ { found=0 }
        found && /^host[[:space:]]*=/ { 
            gsub(/^host[[:space:]]*=[[:space:]]*/, "")
            gsub(/[[:space:]]*$/, "")
            print $0
            exit
        }' "$RCLONE_CONFIG")
        
        if [ -n "$host" ]; then
            echo "$host"
            return 0
        fi
    fi
    
    # 如果找不到host，返回远程名称
    echo "$remote_name"
}

# 读取配置文件
read_config() {
    if [ -f "$CONFIG_FILE" ]; then
        log "📁 读取配置文件: $CONFIG_FILE"
        source "$CONFIG_FILE"
        # 清理Token格式（移除可能多余的"bot"前缀）
        TG_BOT_TOKEN=$(echo "$TG_BOT_TOKEN" | sed 's/^bot//')
        
        # 如果读取到Backup_notification参数，更新NOTIFICATION_METHOD
        if [ -n "$Backup_notification" ] && [ "$Backup_notification" != "0" ]; then
            case "$Backup_notification" in
                "mail")
                    NOTIFICATION_METHOD="email"
                    ;;
                "TG")
                    NOTIFICATION_METHOD="telegram"
                    ;;
                "Mail+TG")
                    NOTIFICATION_METHOD="both"
                    ;;
            esac
        fi
    else
        log "⚠️ 配置文件不存在: $CONFIG_FILE"
    fi
}

# 保存配置到文件
save_config() {
    log "💾 保存配置到文件: $CONFIG_FILE"
    mkdir -p $(dirname "$CONFIG_FILE")
    cat > "$CONFIG_FILE" << EOF
# RojoHome 备份系统配置
SENDER_EMAIL="$SENDER_EMAIL"
EMAIL_AUTH_CODE="$EMAIL_AUTH_CODE"
RECEIVER_EMAIL="$RECEIVER_EMAIL"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
NOTIFICATION_METHOD="$NOTIFICATION_METHOD"
Backup_notification="$Backup_notification"
HOSTNAME="$HOSTNAME"
REMOTE_BACKUP_DIR="$REMOTE_BACKUP_DIR"
BACKUP_METHOD="$BACKUP_METHOD"
BACKUP_CLOUD_TYPES="$BACKUP_CLOUD_TYPES"
DOCKER_IMAGE_BACKUP_MODE="$DOCKER_IMAGE_BACKUP_MODE"
SMTP_SERVER="$SMTP_SERVER"
SMTP_PORT="$SMTP_PORT"
BACKUP_BASE="$BACKUP_BASE"
RETENTION_DAYS="$RETENTION_DAYS"
BACKUP_HOUR="$BACKUP_HOUR"
BACKUP_MINUTE="$BACKUP_MINUTE"
ONEDRIVE_REMOTE_NAME="$ONEDRIVE_REMOTE_NAME"
ONEDRIVE_REMOTE_FOLDER="$ONEDRIVE_REMOTE_FOLDER"
ONEDRIVE_DRIVE_ID="$ONEDRIVE_DRIVE_ID"
ONEDRIVE_DRIVE_TYPE="$ONEDRIVE_DRIVE_TYPE"
GDRIVE_REMOTE_NAME="$GDRIVE_REMOTE_NAME"
EOF
    log "✅ 配置已保存到: $CONFIG_FILE"
}

# 处理ESC取消动作
handle_cancel_action() {
    echo ""
    echo "=========================================================="
    echo "                    操作用户取消                          "
    echo "=========================================================="
    echo "请选择操作:"
    echo "1. 重新运行备份脚本"
    echo "2. 清空Rclone远程配置，重新配置"
    echo "3. 退出脚本"
    echo "=========================================================="
    
    read -p "请选择 [1-3]: " cancel_choice
    
    case $cancel_choice in
        1)
            log "🔄 重新运行备份脚本..."
            # 重新运行当前脚本
            exec "$0" "$@"
            ;;
        2)
            log "🗑️ 清空Rclone远程配置..."
            
            # 备份现有配置文件
            local timestamp=$(date +%Y%m%d_%H%M%S)
            if [ -f "$CONFIG_FILE" ]; then
                cp "$CONFIG_FILE" "$CONFIG_FILE.backup_$timestamp"
                log "📦 已备份配置文件到: $CONFIG_FILE.backup_$timestamp"
            fi
            
            if [ -f "$RCLONE_CONFIG" ]; then
                cp "$RCLONE_CONFIG" "$RCLONE_CONFIG.backup_$timestamp"
                log "📦 已备份Rclone配置到: $RCLONE_CONFIG.backup_$timestamp"
            fi
            
            # 清空配置文件
            > "$CONFIG_FILE"
            > "$RCLONE_CONFIG"
            
            log "✅ 配置文件已清空"
            log "🔧 将重新启动配置流程..."
            
            # 重新运行脚本
            exec "$0" "$@"
            ;;
        3)
            log "👋 退出脚本"
            exit 0
            ;;
        *)
            log "❌ 无效选择，退出脚本"
            exit 1
            ;;
    esac
}

# 倒计时函数，支持ESC检测
countdown_with_esc() {
    local seconds=$1
    local message="$2"
    local action_on_esc="$3"
    
    echo ""
    echo "⏰ $message"
    echo "按 ESC 键可以取消并重新配置"
    echo ""
    
    for ((i=seconds; i>=1; i--)); do
        printf "\r倒计时: %02d 秒" $i
        # 检测ESC键
        read -t 1 -n 1 key
        if [[ $key = $'\e' ]]; then
            echo ""
            echo "ESC键检测到，取消当前操作..."
            eval "$action_on_esc"
            return 1
        fi
    done
    echo ""
    return 0
}

# 配置备份计划（修改版：只配置小时，分钟固定为0）
configure_backup_schedule() {
    echo ""
    echo "=========================================================="
    echo "                   配置备份计划                           "
    echo "=========================================================="
    
    # 配置备份文件保留天数
    read -p "请输入备份文件保留天数 (默认: 7天): " input_days
    if [[ -n "$input_days" && "$input_days" =~ ^[0-9]+$ ]]; then
        RETENTION_DAYS=$input_days
    fi
    log "✅ 设置保留天数: $RETENTION_DAYS天"
    
    # 配置每日备份时间（只配置小时）
    echo ""
    echo "请设置每日备份时间 (24小时制)"
    read -p "请输入备份小时 (0-23，默认: 2 表示凌晨2点): " input_hour
    if [[ -n "$input_hour" && "$input_hour" =~ ^(0[0-9]|1[0-9]|2[0-3]|[0-9])$ ]]; then
        BACKUP_HOUR=$((10#$input_hour))  # 防止前导0被解释为八进制
    else
        BACKUP_HOUR=2
    fi
    
    # 分钟固定为0
    BACKUP_MINUTE=0
    
    log "✅ 设置备份时间: $BACKUP_HOUR:$BACKUP_MINUTE"
    
    # 创建/更新crontab
    configure_crontab
}

# 配置crontab
configure_crontab() {
    log "⏰ 配置crontab计划任务..."
    
    # 获取脚本绝对路径
    SCRIPT_PATH=$(realpath "$0")
    
    # 创建cron文件
    CRON_JOB="$BACKUP_MINUTE $BACKUP_HOUR * * * root $SCRIPT_PATH\n"
    
    echo -e "$CRON_JOB" > "$CRON_FILE"
    
    if [ $? -eq 0 ]; then
        log "✅ crontab配置成功"
        log "📅 计划任务已设置: 每天 $BACKUP_HOUR:$BACKUP_MINUTE 执行备份"
    else
        log "❌ crontab配置失败"
    fi
}

# 显示备份计划配置摘要
show_backup_plan_summary() {
    echo ""
    echo "=========================================================="
    echo "              备份计划配置完成                            "
    echo "=========================================================="
    echo "📅 备份保留天数: $RETENTION_DAYS天"
    echo "⏰ 每日备份时间: $BACKUP_HOUR:$BACKUP_MINUTE"
    echo "📁 本地备份存储路径: $BACKUP_BASE"
    
    # 显示远程备份路径
    if command -v rclone &> /dev/null && [ -f "$RCLONE_CONFIG" ]; then
        local remotes=$(rclone listremotes 2>/dev/null)
        if [ -n "$remotes" ]; then
            echo "📡 远程备份存储路径:"
            while IFS= read -r remote; do
                if [ -n "$remote" ]; then
                    local remote_name=$(echo "$remote" | tr -d ':')
                    local remote_host=$(get_remote_host "$remote_name")
                    echo "   $remote_name ($remote_host): $REMOTE_BACKUP_DIR/"
                fi
            done <<< "$remotes"
        else
            echo "📡 远程备份存储路径: 未配置远程存储"
        fi
    else
        echo "📡 远程备份存储路径: Rclone未配置"
    fi
    
    # 显示网盘备份信息
    if [ "$BACKUP_METHOD" = "cloud" ] || [ "$BACKUP_METHOD" = "both_cloud" ] || [ "$BACKUP_METHOD" = "all" ]; then
        if [ -n "$BACKUP_CLOUD_TYPES" ]; then
            echo "☁️  网盘备份信息:"
            IFS=',' read -ra cloud_types <<< "$BACKUP_CLOUD_TYPES"
            for cloud_type in "${cloud_types[@]}"; do
                case "$cloud_type" in
                    "baidu")
                        echo "   百度网盘目录: $BYPY_CLOUD_DIR"
                        ;;
                    "onedrive")
                        echo "   OneDrive远程名称: $ONEDRIVE_REMOTE_NAME"
                        echo "   OneDrive文件夹: $ONEDRIVE_REMOTE_FOLDER"
                        echo "   Drive ID: $ONEDRIVE_DRIVE_ID"
                        echo "   Drive Type: $ONEDRIVE_DRIVE_TYPE"
                        ;;
                    "google")
                        echo "   Google云端硬盘配置完成"
                        echo "   远程名称: $GDRIVE_REMOTE_NAME"
                        ;;
                esac
            done
        fi
    fi
    
    echo "=========================================================="
}

# 配置Docker镜像备份方式
configure_docker_image_backup() {
    echo ""
    echo "=========================================================="
    echo "                配置Docker镜像备份方式                    "
    echo "=========================================================="
    echo "请选择Docker镜像备份方式:"
    echo "1. 不备份Docker镜像 (备份文件较小，恢复时需要重新拉取镜像)"
    echo "2. 只备份运行中容器的镜像 (推荐，平衡备份大小和恢复便利)"
    echo "3. 备份所有已拉取的镜像 (备份文件较大，但恢复最完整)"
    echo "4. 只备份镜像名称和版本号 (仅记录，恢复时需要重新拉取)"
    echo "=========================================================="
    
    read -p "请选择 [1-4]: " choice
    
    case $choice in
        1)
            DOCKER_IMAGE_BACKUP_MODE="none"
            log "✅ Docker镜像备份: 不备份镜像"
            ;;
        2)
            DOCKER_IMAGE_BACKUP_MODE="running"
            log "✅ Docker镜像备份: 只备份运行中容器的镜像"
            log "⚠️  注意: 备份文件会比不备份镜像时大一些"
            ;;
        3)
            DOCKER_IMAGE_BACKUP_MODE="all"
            log "✅ Docker镜像备份: 备份所有已拉取的镜像"
            log "⚠️  注意: 备份文件可能会比较大，请确保有足够的磁盘空间"
            ;;
        4)
            DOCKER_IMAGE_BACKUP_MODE="list"
            log "✅ Docker镜像备份: 只备份镜像名称和版本号"
            ;;
        *)
            log "❌ 无效选择，默认使用不备份镜像"
            DOCKER_IMAGE_BACKUP_MODE="none"
            ;;
    esac
    
    # 保存配置
    save_config
}

# 检查并安装邮件客户端
check_and_install_email_client() {
    log "🔍 检查邮件客户端安装状态..."
    
    # 检查 msmtp
    if command -v msmtp &> /dev/null; then
        log "✅ msmtp 已安装"
        return 0
    fi
    
    log "📧 安装邮件客户端 msmtp..."
    
    # 根据系统类型安装
    if command -v apt &> /dev/null; then
        apt update && apt install -y msmtp msmtp-mta mailutils curl
    elif command -v yum &> /dev/null; then
        yum -y install msmtp mailx curl
    elif command -v dnf &> /dev/null; then
        dnf -y install msmtp mailx curl
    else
        log "❌ 无法确定包管理器，请手动安装 msmtp"
        return 1
    fi
    
    if command -v msmtp &> /dev/null; then
        log "✅ msmtp 安装成功"
        return 0
    else
        log "❌ msmtp 安装失败"
        return 1
    fi
}

# 自动配置防火墙放通端口
configure_firewall_port() {
    local port="$1"
    local protocol="${2:-tcp}"
    
    log "配置防火墙放通端口: $port/$protocol"
    
    # 检查UFW (Ubuntu/Debian)
    if command -v ufw &> /dev/null; then
        if ufw status | grep -q "Status: active"; then
            log "检测到UFW防火墙，放通端口 $port/$protocol"
            ufw allow $port/$protocol
            return $?
        fi
    fi
    
    # 检查firewalld (CentOS/RHEL)
    if command -v firewall-cmd &> /dev/null; then
        if systemctl is-active --quiet firewalld; then
            log "检测到firewalld，放通端口 $port/$protocol"
            firewall-cmd --permanent --add-port=$port/$protocol
            firewall-cmd --reload
            return $?
        fi
    fi
    
    # 检查iptables
    if command -v iptables &> /dev/null; then
        log "检测到iptables，放通端口 $port/$protocol"
        iptables -A INPUT -p $protocol --dport $port -j ACCEPT
        # 尝试保存iptables规则
        if command -v iptables-save &> /dev/null; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
            iptables-save > /etc/sysconfig/iptables 2>/dev/null
        fi
        return $?
    fi
    
    log "⚠️ 未检测到已知防火墙，请手动配置端口 $port/$protocol"
    return 0
}

# 清理旧的msmtp配置
cleanup_old_msmtp_config() {
    log "清理旧的msmtp配置..."
    
    # 删除可能存在的旧配置文件
    local config_files=(
        "/root/.msmtprc"
        "/etc/msmtprc"
        "/home/$USER/.msmtprc"
    )
    
    for config_file in "${config_files[@]}"; do
        if [ -f "$config_file" ]; then
            log "删除旧配置文件: $config_file"
            rm -f "$config_file"
        fi
    done
    
    # 检查并删除包含错误配置的文件
    find /etc /root /home -name "*.msmtprc" -o -name "msmtprc" 2>/dev/null | while read file; do
        if grep -q "tls_ssl" "$file" 2>/dev/null; then
            log "删除包含错误配置的文件: $file"
            rm -f "$file"
        fi
    done
}

# 配置邮件通知
configure_email_notification() {
    echo ""
    echo "=========================================================="
    echo "                   配置邮件通知                           "
    echo "=========================================================="
    echo "📧 邮件服务配置说明:"
    echo "1. QQ邮箱: 需要开启SMTP服务，获取授权码"
    echo "   - 登录QQ邮箱 -> 设置 -> 账户 -> 开启POP3/SMTP服务 -> 生成授权码"
    echo "2. 163邮箱: 需要开启SMTP服务，获取授权码"
    echo "   - 登录163邮箱 -> 设置 -> POP3/SMTP/IMAP -> 开启SMTP服务 -> 获取授权码"
    echo "3. Gmail: 需要开启两步验证，使用应用专用密码"
    echo "   - 登录Gmail -> 设置 -> 安全性 -> 两步验证 -> 应用专用密码"
    echo "4. 其他邮箱: 参考相应邮箱的SMTP配置"
    echo ""
    echo "🔐 重要提示: 必须使用授权码，而不是邮箱登录密码！"
    echo "=========================================================="
    
    # 配置发送邮箱
    read -p "📤 请输入发送邮箱地址 (例如: your_email@qq.com): " SENDER_EMAIL
    
    if [[ ! "$SENDER_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log "❌ 邮箱地址格式不正确"
        return 1
    fi
    
    # 配置邮箱授权码
    echo ""
    echo "🔑 授权码获取指引:"
    echo "- QQ邮箱: 登录网页版QQ邮箱 -> 设置 -> 账户 -> 开启POP3/SMTP -> 生成授权码"
    echo "- 163邮箱: 登录网页版163邮箱 -> 设置 -> POP3/SMTP/IMAP -> 开启SMTP -> 获取授权码"
    echo "- Gmail: 需要先开启两步验证，然后生成应用专用密码"
    echo ""
    read -s -p "请输入邮箱授权码 (不会显示): " EMAIL_AUTH_CODE
    echo ""
    
    if [ -z "$EMAIL_AUTH_CODE" ]; then
        log "❌ 授权码不能为空"
        return 1
    fi
    
    # 配置接收邮箱
    read -p "📥 请输入接收通知的邮箱地址: " RECEIVER_EMAIL
    
    if [[ ! "$RECEIVER_EMAIL" =~ ^[a-zAZ0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log "❌ 接收邮箱地址格式不正确"
        return 1
    fi
    
    # 安装邮件客户端
    if ! check_and_install_email_client; then
        log "❌ 邮件客户端安装失败，无法配置邮件通知"
        return 1
    fi
    
    # 清理旧的错误配置
    cleanup_old_msmtp_config
    
    # 配置 msmtp
    if configure_msmtp; then
        # 测试邮件发送
        log "测试邮件发送..."
        if send_test_email; then
            log "✅ 邮件通知配置成功"
            return 0
        else
            log "❌ 邮件测试发送失败，请检查配置"
            return 1
        fi
    else
        log "❌ msmtp配置失败"
        return 1
    fi
}

# 配置 msmtp
configure_msmtp() {
    log "配置 msmtp..."
    
    local msmtp_config="/etc/msmtprc"
    local msmtp_log="/var/log/msmtp.log"
    
    # 检测邮箱服务商并配置
    if [[ "$SENDER_EMAIL" =~ @qq\.com$ ]]; then
        SMTP_SERVER="smtp.qq.com"
        SMTP_PORT="587"
        log "✅ 检测到QQ邮箱，使用QQ邮箱SMTP配置"
        log "⚠️  请确保已在QQ邮箱中开启SMTP服务并获取授权码"
        # 自动放通587端口
        configure_firewall_port "587" "tcp"
    elif [[ "$SENDER_EMAIL" =~ @163\.com$ ]]; then
        SMTP_SERVER="smtp.163.com" 
        SMTP_PORT="465"
        log "✅ 检测到163邮箱，使用163邮箱SMTP配置"
        # 自动放通465端口
        configure_firewall_port "465" "tcp"
    elif [[ "$SENDER_EMAIL" =~ @gmail\.com$ ]]; then
        SMTP_SERVER="smtp.gmail.com"
        SMTP_PORT="587"
        log "✅ 检测到Gmail，使用Gmail SMTP配置"
        # 自动放通587端口
        configure_firewall_port "587" "tcp"
    else
        # 默认配置，用户需要手动输入
        read -p "📡 请输入SMTP服务器地址: " SMTP_SERVER
        read -p "🔢 请输入SMTP端口 (通常587或465): " SMTP_PORT
        # 自动放通用户指定的端口
        if [[ "$SMTP_PORT" =~ ^[0-9]+$ ]]; then
            configure_firewall_port "$SMTP_PORT" "tcp"
        fi
    fi
    
    # 创建 msmtp 配置目录
    mkdir -p /etc/msmtp
    
    # 创建正确的 msmtp 配置
    cat > "$msmtp_config" << EOF
# MSMTP 配置文件
# 生成时间: $(date)
defaults
auth on
tls on
tls_starttls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile ${msmtp_log}
syslog on

# 备份系统账户
account backup_system
host ${SMTP_SERVER}
port ${SMTP_PORT}
from ${SENDER_EMAIL}
user ${SENDER_EMAIL}
password ${EMAIL_AUTH_CODE}

# 设置为默认账户
account default : backup_system
EOF
    
    # 设置权限
    chmod 600 "$msmtp_config"
    chmod 600 "$msmtp_config"
    chown root:root "$msmtp_config"
    
    # 创建日志文件
    touch "$msmtp_log"
    chmod 644 "$msmtp_log"
    
    log "✅ msmtp 配置完成: $msmtp_config"
    log "📧 SMTP服务器: $SMTP_SERVER:$SMTP_PORT"
    log "📨 发送邮箱: $SENDER_EMAIL"
    log "📥 接收邮箱: $RECEIVER_EMAIL"
    
    # 显示配置内容用于调试
    log "msmtp 配置内容:"
    cat "$msmtp_config" | while read line; do
        log "  $line"
    done
    
    return 0
}

# 发送测试邮件
send_test_email() {
    local subject="✅ RojoHome备份系统测试邮件 - $HOSTNAME"
    local message="这是一封测试邮件，用于验证RojoHome备份系统的邮件通知功能。

📋 邮件配置信息:
- 发送邮箱: $SENDER_EMAIL
- 接收邮箱: $RECEIVER_EMAIL  
- 设备名称: $HOSTNAME
- 测试时间: $(date '+%Y-%m-%d %H:%M:%S')
- SMTP服务器: $SMTP_SERVER:$SMTP_PORT

✅ 如果收到此邮件，说明邮件通知配置成功！

🔔 系统将在每天 $BACKUP_HOUR:$BACKUP_MINUTE 自动执行备份，并在完成后发送通知。

--
RojoHome备份系统
自动化数据保护解决方案"

    log "发送测试邮件到: $RECEIVER_EMAIL"
    
    # 使用多种方式尝试发送邮件
    local success=false
    
    # 方式1: 使用 msmtp (带详细日志)
    if command -v msmtp &> /dev/null && [ -f "/etc/msmtprc" ]; then
        log "尝试使用 msmtp 发送邮件..."
        local debug_log="/tmp/msmtp_debug_$$.log"
        
        # 创建临时邮件文件
        local temp_mail="/tmp/test_mail_$$.txt"
        echo -e "Subject: $subject\n\n$message" > "$temp_mail"
        
        if msmtp -v "$RECEIVER_EMAIL" < "$temp_mail" > "$debug_log" 2>&1; then
            success=true
            log "✅ msmtp 发送成功"
        else
            log "❌ msmtp 发送失败，查看调试信息..."
            if [ -f "$debug_log" ]; then
                log "msmtp 调试日志:"
                while IFS= read -r line; do
                    log "  $line"
                done < "$debug_log"
            fi
        fi
        
        rm -f "$debug_log" "$temp_mail"
    fi
    
    # 方式2: 使用 sendmail (备用)
    if [ "$success" = false ] && command -v sendmail &> /dev/null; then
        log "尝试使用 sendmail 发送邮件..."
        local temp_mail="/tmp/test_mail_$$.txt"
        cat > "$temp_mail" << EOF
From: $SENDER_EMAIL
To: $RECEIVER_EMAIL
Subject: $subject

$message
EOF
        if sendmail -f "$SENDER_EMAIL" "$RECEIVER_EMAIL" < "$temp_mail" 2>/dev/null; then
            success=true
            log "✅ sendmail 发送成功"
        else
            log "❌ sendmail 发送失败"
        fi
        rm -f "$temp_mail"
    fi
    
    # 方式3: 使用 mail 命令 (备用)
    if [ "$success" = false ] && command -v mail &> /dev/null; then
        log "尝试使用 mail 命令发送邮件..."
        if echo "$message" | mail -s "$subject" -r "$SENDER_EMAIL" "$RECEIVER_EMAIL" 2>/dev/null; then
            success=true
            log "✅ mail 命令发送成功"
        else
            log "❌ mail 命令发送失败"
        fi
    fi
    
    if [ "$success" = true ]; then
        log "✅ 测试邮件发送成功"
        return 0
    else
        log "❌ 所有邮件发送方式都失败了"
        log "⚠️ 请检查以下配置:"
        log "  - 发送邮箱: $SENDER_EMAIL"
        log "  - SMTP服务器: $SMTP_SERVER"
        log "  - 端口: $SMTP_PORT"
        log "  - 授权码是否正确"
        log "  - 是否已开启SMTP服务"
        log "  - 网络连接是否正常"
        log "  - 防火墙是否阻止SMTP连接"
        return 1
    fi
}

# 配置通知方法（修改版：添加Backup_notification参数）
configure_notification() {
    echo ""
    echo "=========================================================="
    echo "                   配置备份通知方法                       "
    echo "=========================================================="
    echo "请选择通知方法:"
    echo "1. 电子邮件 (Email)"
    echo "2. Telegram 机器人"
    echo "3. 电子邮件 + Telegram"
    echo "4. 跳过通知配置"
    echo "=========================================================="
    
    read -p "请选择 [1-4]: " choice
    
    case $choice in
        1)
            NOTIFICATION_METHOD="email"
            Backup_notification="mail"
            if configure_email_notification; then
                log "✅ 邮件通知配置完成"
                save_config
                # 5秒倒计时确认
                if ! countdown_with_esc 5 "配置完成，5秒后自动进入下一步" "configure_notification"; then
                    return 1
                fi
            else
                log "❌ 邮件通知配置失败"
                NOTIFICATION_METHOD=""
                Backup_notification="0"
                SENDER_EMAIL=""
                EMAIL_AUTH_CODE=""
                RECEIVER_EMAIL=""
                SMTP_SERVER=""
                SMTP_PORT=""
            fi
            ;;
        2)
            NOTIFICATION_METHOD="telegram"
            Backup_notification="TG"
            echo ""
            echo "Telegram 机器人配置:"
            echo "1. 在Telegram中搜索 @BotFather"
            echo "2. 发送 /newbot 创建新机器人"
            echo "3. 获取机器人Token (格式: 1234567890:ABCdefGHIjklMNoPQRsTUVwxyZ)"
            echo "4. 在Telegram中搜索 @userinfobot 获取您的Chat ID"
            echo ""
            read -p "🤖 请输入Telegram Bot Token: " TG_BOT_TOKEN
            read -p "💬 请输入Telegram Chat ID: " TG_CHAT_ID
            
            # 清理Token格式
            TG_BOT_TOKEN=$(echo "$TG_BOT_TOKEN" | sed 's/^bot//')
            
            if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
                log "❌ Telegram配置不完整，跳过Telegram配置"
                NOTIFICATION_METHOD=""
                Backup_notification="0"
                TG_BOT_TOKEN=""
                TG_CHAT_ID=""
            else
                # 测试Telegram连接
                log "测试Telegram连接..."
                if send_telegram_notification "🔔 RojoHome备份系统测试通知

✅ Telegram通知配置成功！
🖥️ 设备: $HOSTNAME
📅 时间: $(date '+%Y-%m-%d %H:%M:%S')
⏰ 备份时间: 每天 $BACKUP_HOUR:$BACKUP_MINUTE"; then
                    log "✅ Telegram通知配置完成"
                    save_config
                    # 5秒倒计时确认
                    if ! countdown_with_esc 5 "配置完成，5秒后自动进入下一步" "configure_notification"; then
                        return 1
                    fi
                else
                    log "❌ Telegram连接测试失败，请检查Token和Chat ID"
                    NOTIFICATION_METHOD=""
                    Backup_notification="0"
                    TG_BOT_TOKEN=""
                    TG_CHAT_ID=""
                fi
            fi
            ;;
        3)
            NOTIFICATION_METHOD="both"
            Backup_notification="Mail+TG"
            local email_success=false
            local telegram_success=false
            
            # 配置邮件
            if configure_email_notification; then
                email_success=true
                log "✅ 邮件通知配置完成"
            else
                log "❌ 邮件通知配置失败"
                SENDER_EMAIL=""
                EMAIL_AUTH_CODE=""
                RECEIVER_EMAIL=""
                SMTP_SERVER=""
                SMTP_PORT=""
            fi
            
            # 配置Telegram
            echo ""
            echo "Telegram 机器人配置:"
            echo "1. 在Telegram中搜索 @BotFather"
            echo "2. 发送 /newbot 创建新机器人"
            echo "3. 获取机器人Token (格式: 1234567890:ABCdefGHIjklMNoPQRsTUVwxyZ)"
            echo "4. 在Telegram中搜索 @userinfobot 获取您的Chat ID"
            echo ""
            read -p "🤖 请输入Telegram Bot Token: " TG_BOT_TOKEN
            read -p "💬 请输入Telegram Chat ID: " TG_CHAT_ID
            
            # 清理Token格式
            TG_BOT_TOKEN=$(echo "$TG_BOT_TOKEN" | sed 's/^bot//')
            
            if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
                log "❌ Telegram配置不完整，跳过Telegram配置"
                TG_BOT_TOKEN=""
                TG_CHAT_ID=""
            else
                # 测试Telegram连接
                log "测试Telegram连接..."
                if send_telegram_notification "🔔 RojoHome备份系统测试通知

✅ Telegram通知配置成功！
🖥️ 设备: $HOSTNAME
📅 时间: $(date '+%Y-%m-%d %H:%M:%S')
⏰ 备份时间: 每天 $BACKUP_HOUR:$BACKUP_MINUTE"; then
                    telegram_success=true
                    log "✅ Telegram通知配置完成"
                else
                    log "❌ Telegram连接测试失败，请检查Token和Chat ID"
                    TG_BOT_TOKEN=""
                    TG_CHAT_ID=""
                fi
            fi
            
            # 检查至少一种通知方法配置成功
            if [ "$email_success" = true ] || [ "$telegram_success" = true ]; then
                save_config
                # 5秒倒计时确认
                if ! countdown_with_esc 5 "配置完成，5秒后自动进入下一步" "configure_notification"; then
                    return 1
                fi
            else
                log "❌ 两种通知方法都配置失败，跳过通知配置"
                NOTIFICATION_METHOD=""
                Backup_notification="0"
            fi
            ;;
        4)
            log "⏭️ 跳过通知配置"
            NOTIFICATION_METHOD=""
            Backup_notification="0"
            # 5秒倒计时确认
            if ! countdown_with_esc 5 "配置完成，5秒后自动进入下一步" "configure_notification"; then
                return 1
            fi
            ;;
        *)
            log "❌ 无效选择，跳过通知配置"
            NOTIFICATION_METHOD=""
            Backup_notification="0"
            ;;
    esac
    
    # 保存配置
    save_config
}

# 配置备份方式
configure_backup_method() {
    echo ""
    echo "=========================================================="
    echo "                   配置备份方式                           "
    echo "=========================================================="
    echo "请选择备份方式:"
    echo "1. 仅本地备份"
    echo "2. 仅远程备份 (Linux服务器)"
    echo "3. 仅网盘备份(百度网盘、谷歌云端硬盘、微软OneDrive)"
    echo "4. 本地+远程备份"
    echo "5. 本地+网盘备份"
    echo "6. 本地+远程+网盘备份"
    echo "=========================================================="
    
    read -p "请选择 [1-6]: " choice
    
    case $choice in
        1)
            BACKUP_METHOD="local"
            log "✅ 备份方式: 仅本地备份"
            ;;
        2)
            BACKUP_METHOD="remote"
            log "✅ 备份方式: 仅远程备份"
            configure_remote_backup
            ;;
        3)
            BACKUP_METHOD="cloud"
            log "✅ 备份方式: 仅网盘备份"
            configure_cloud_backup
            ;;
        4)
            BACKUP_METHOD="both_remote"
            log "✅ 备份方式: 本地+远程备份"
            configure_remote_backup
            ;;
        5)
            BACKUP_METHOD="both_cloud"
            log "✅ 备份方式: 本地+网盘备份"
            configure_cloud_backup
            ;;
        6)
            BACKUP_METHOD="all"
            log "✅ 备份方式: 本地+远程+网盘备份"
            configure_remote_backup
            configure_cloud_backup
            ;;
        *)
            log "❌ 无效选择，默认使用仅本地备份"
            BACKUP_METHOD="local"
            ;;
    esac
    
    # 保存配置
    save_config
}

# 配置远程备份（修改版：添加处理逻辑）
configure_remote_backup() {
    echo ""
    echo "=========================================================="
    echo "                   配置远程设备(Linux服务器)                           "
    echo "=========================================================="
    
    # 检查并安装Rclone
    if ! check_and_install_rclone; then
        log "❌ Rclone安装失败，无法配置远程备份"
        return 1
    fi
    
    # 检查现有Rclone配置并询问用户如何处理
    if [ -f "$RCLONE_CONFIG" ] && rclone listremotes &>/dev/null; then
        local existing_remotes=$(rclone listremotes)
        if [ -n "$existing_remotes" ]; then
            echo ""
            echo "📋 检测到现有Rclone远程配置:"
            echo "$existing_remotes"
            echo ""
            echo "请选择配置方式:"
            echo "1. 在现有配置上追加新的远程服务器配置"
            echo "2. 清空现有配置，重新配置远程服务器"
            echo "3. 使用现有配置，跳过远程服务器配置"
            echo ""
            read -p "请选择 [1-3]: " config_choice
            
            case $config_choice in
                1)
                    log "✅ 将在现有配置上追加新的远程服务器配置"
                    echo "注意：后续远程备份会按照配置文件一个一个进行远程备份"
                    read -p "请输入远程备份服务器数量: " remote_count
                    
                    if ! [[ "$remote_count" =~ ^[1-9][0-9]*$ ]]; then
                        log "❌ 请输入有效的数字"
                        return 1
                    fi
                    
                    for ((i=1; i<=remote_count; i++)); do
                        echo ""
                        echo "--- 配置第 $i 个远程服务器 ---"
                        configure_single_remote $i
                    done
                    ;;
                2)
                    log "🗑️ 清空现有Rclone配置..."
                    > "$RCLONE_CONFIG"
                    read -p "请输入远程备份服务器数量: " remote_count
                    
                    if ! [[ "$remote_count" =~ ^[1-9][0-9]*$ ]]; then
                        log "❌ 请输入有效的数字"
                        return 1
                    fi
                    
                    for ((i=1; i<=remote_count; i++)); do
                        echo ""
                        echo "--- 配置第 $i 个远程服务器 ---"
                        configure_single_remote $i
                    done
                    ;;
                3)
                    log "⏭️ 使用现有配置，跳过远程服务器配置"
                    # 检查现有配置是否为空
                    if [ -z "$existing_remotes" ]; then
                        log "⚠️ 现有Rclone配置为空，将只有本地备份"
                        echo ""
                        echo "=========================================================="
                        echo "                    警告                               "
                        echo "=========================================================="
                        echo "当前Rclone配置为空，将只有本地备份！"
                        echo "仅有本地备份存在风险，建议配置远程备份。"
                        echo ""
                        
                        # 5秒倒计时，允许用户按ESC重新配置
                        if ! countdown_with_esc 5 "5秒后自动继续（按ESC重新配置远程备份）" "configure_remote_backup"; then
                            return 1
                        fi
                        
                        # 更新备份方式为仅本地
                        if [ "$BACKUP_METHOD" = "both_remote" ]; then
                            BACKUP_METHOD="local"
                            log "✅ 更新备份方式为: 仅本地备份"
                            save_config
                        elif [ "$BACKUP_METHOD" = "all" ]; then
                            BACKUP_METHOD="both_cloud"
                            log "✅ 更新备份方式为: 本地+网盘备份"
                            save_config
                        fi
                    else
                        log "✅ 使用现有远程配置:"
                        echo "$existing_remotes"
                    fi
                    return 0
                    ;;
                *)
                    log "❌ 无效选择，使用现有配置"
                    return 0
                    ;;
            esac
        fi
    else
        # 没有现有配置，直接配置新的
        read -p "请输入远程备份服务器数量: " remote_count
        
        if ! [[ "$remote_count" =~ ^[1-9][0-9]*$ ]]; then
            log "❌ 请输入有效的数字"
            return 1
        fi
        
        for ((i=1; i<=remote_count; i++)); do
            echo ""
            echo "--- 配置第 $i 个远程服务器 ---"
            configure_single_remote $i
        done
    fi
    
    log "✅ 远程备份配置完成"
}

# 配置单个远程服务器
configure_single_remote() {
    local index=$1
    
    read -p "请输入远程服务器名称 (例如: aly, tencent等): " remote_name
    read -p "请输入远程服务器IP或域名: " remote_host
    read -p "请输入SSH端口号 (默认22): " remote_port
    remote_port=${remote_port:-22}
    read -p "请输入远程备份路径: " remote_path
    read -p "请输入用户名: " remote_user
    
    # 自动放通SSH端口
    configure_firewall_port "$remote_port" "tcp"
    
    echo ""
    echo "请选择认证方式:"
    echo "1. 密码认证"
    echo "2. 密钥认证"
    read -p "请选择 [1-2]: " auth_choice
    
    local auth_method=""
    local password=""
    local key_file=""
    
    case $auth_choice in
        1)
            auth_method="password"
            read -s -p "请输入密码: " password
            echo ""
            ;;
        2)
            auth_method="key"
            read -p "请输入密钥文件名称 (已上传到 /root/.ssh/): " key_file
            key_file="/root/.ssh/$key_file"
            
            # 设置密钥权限
            if [ -f "$key_file" ]; then
                chmod 600 "$key_file"
                chmod 700 "/root/.ssh/"
                chown root:root "$key_file"
                log "✅ 密钥权限设置完成: $key_file"
            else
                log "❌ 密钥文件不存在: $key_file"
                return 1
            fi
            ;;
        *)
            log "❌ 无效选择，跳过此服务器"
            return 1
            ;;
    esac
    
    # 创建Rclone配置
    create_rclone_config "$remote_name" "$remote_host" "$remote_port" "$remote_path" "$remote_user" "$auth_method" "$password" "$key_file"
}

# 配置网盘备份（修改版：支持多选，添加第4个选项"不使用网盘备份"）
configure_cloud_backup() {
    echo ""
    echo "=========================================================="
    echo "                   配置网盘备份                           "
    echo "=========================================================="
    echo "请选择网盘类型（可多选，用逗号分隔，如: 1,2,3,4）:"
    echo "1. 百度网盘 (bypy)"
    echo "2. Google云端硬盘 (交互式配置)"
    echo "3. 微软OneDrive (需要rclone配置)"
    echo "4. 不使用网盘备份"
    echo "=========================================================="
    
    read -p "请选择 [1-4，可多选如 1,2,3]: " cloud_choice_input
    
    # 处理用户输入，支持多选
    IFS=',' read -ra cloud_choices <<< "$cloud_choice_input"
    local selected_types=()
    
    # 检查是否选择了"不使用网盘备份"
    for choice in "${cloud_choices[@]}"; do
        if [ "$choice" = "4" ]; then
            echo ""
            echo "=========================================================="
            echo "             选择不使用网盘备份                          "
            echo "=========================================================="
            
            # 5秒倒计时，允许用户按ESC重新配置
            if ! countdown_with_esc 5 "5秒后将跳过网盘配置（按ESC重新配置网盘）" "configure_cloud_backup"; then
                return 1
            fi
            
            log "✅ 用户选择不使用网盘备份"
            BACKUP_CLOUD_TYPES=""
            return 0
        fi
    done
    
    for choice in "${cloud_choices[@]}"; do
        case "$choice" in
            "1")
                selected_types+=("baidu")
                ;;
            "2")
                selected_types+=("google")
                ;;
            "3")
                selected_types+=("onedrive")
                ;;
            *)
                log "⚠️ 跳过无效选项: $choice"
                ;;
        esac
    done
    
    if [ ${#selected_types[@]} -eq 0 ]; then
        log "❌ 未选择任何有效网盘类型，默认使用百度网盘"
        selected_types=("baidu")
    fi
    
    # 将选择的网盘类型保存为逗号分隔的字符串
    BACKUP_CLOUD_TYPES=$(IFS=','; echo "${selected_types[*]}")
    log "✅ 选择的网盘类型: $BACKUP_CLOUD_TYPES"
    
    # 按顺序配置每个网盘
    local success_count=0
    for cloud_type in "${selected_types[@]}"; do
        case "$cloud_type" in
            "baidu")
                log "📦 配置百度网盘..."
                if install_and_configure_bypy; then
                    ((success_count++))
                fi
                ;;
            "google")
                log "📦 配置 Google Drive..."
                if configure_google_drive_simple; then
                    ((success_count++))
                fi
                ;;
            "onedrive")
                log "📦 配置 Microsoft OneDrive..."
                if configure_onedrive_backup; then
                    ((success_count++))
                fi
                ;;
        esac
        echo ""
    done
    
    if [ $success_count -gt 0 ]; then
        log "✅ 网盘配置完成，成功配置 $success_count/${#selected_types[@]} 个网盘"
    else
        log "❌ 网盘配置失败，未成功配置任何网盘"
        BACKUP_CLOUD_TYPES=""
    fi
    
    # 保存配置
    save_config
}

# 生成 Google Drive 授权字符串
generate_google_drive_auth_string() {
    echo "正在生成 Google Drive 授权字符串..."
    
    # 生成 scope=drive 的 base64 编码（去掉末尾的 =）
    local scope_base64=$(echo -n '{"scope":"drive"}' | base64 | tr -d '=')
    
    log "✅ 生成授权字符串: $scope_base64"
    
    # 生成授权命令
    local auth_command="rclone authorize \"drive\" \"$scope_base64\""
    
    echo ""
    echo "=========================================================="
    echo "       Google Drive 授权命令已生成                          "
    echo " 教程：https://halo.dbhzj.top/archives/linux-xia-rclonegoogle-yun-duan-ying-pan-huo-qu-token-shi-xian-zi-dong-shang-chuan       "
    echo "=========================================================="
    echo ""
    echo "📋 配置说明:"
    echo "Google Drive 授权命令: $auth_command"
    echo ""
    echo "📝 配置流程概述:"
    echo "1. 将显示授权命令，需要您在有浏览器的电脑（例如 Windows PowerShell）上执行"
    echo "2. 然后登录 Google 账号，显示成功"
    echo "3. 授权成功后，会在 PowerShell 中看到一串授权码（JSON 格式）"
    echo "4. 将获得的授权码粘贴回来，回车"
    echo ""
    echo "请复制以下命令到有浏览器的电脑上执行："
    echo "=========================================="
    echo "$auth_command"
    echo "=========================================="
    echo ""
    
    echo "$scope_base64"
}

# 简单的 Google Drive 配置
configure_google_drive_simple() {
    echo ""
    echo "=========================================================="
    echo "             配置 Google Drive (简单方式)                "
    echo "=========================================================="
    
    # 检查并安装 Rclone
    if ! check_and_install_rclone; then
        log "❌ Rclone 安装失败，无法配置 Google Drive"
        return 1
    fi
    
    # 检查是否已存在 gdrive 配置
    if rclone listremotes | grep -q "gdrive:"; then
        log "⚠️  检测到已存在的 gdrive 配置"
        read -p "是否重新配置？(y/N): " reconfigure
        if [[ ! "$reconfigure" =~ ^[Yy]$ ]]; then
            log "⏭️ 使用现有 gdrive 配置"
            GDRIVE_REMOTE_NAME="gdrive"
            save_config
            return 0
        fi
    fi
    
    echo "生成 Google Drive 授权命令..."
    
    # 生成授权字符串
    local auth_string=$(generate_google_drive_auth_string)
    
    # 提示用户在浏览器端执行授权
    echo ""
    echo "操作步骤:"
    echo "1. 复制上面的授权命令"
    echo "2. 在有浏览器可以登录 Google 账号的电脑上（如 Windows PowerShell）执行该命令"
    echo "3. 按照提示完成 Google 账号授权"
    echo "4. 授权成功后，会得到一串授权码（JSON 格式）"
    echo ""
    echo "授权码格式示例:"
    echo '{"access_token":"ya29.a0Aa7pCA_...","token_type":"Bearer","refresh_token":"1//0ecJmQ7sdgRhCCgYIARA...","expiry":"2025-12-09T23:38:38.403518774+08:00","expires_in":3599}'
    echo ""
    
    # 读取用户输入的授权码
    echo "请将授权码粘贴到这里（按 ESC 键取消）:"
    local auth_code=""
    while IFS= read -r line; do
        # 检查是否按ESC键
        if [[ $line =~ $'\e' ]]; then
            echo ""
            echo "ESC键检测到，取消输入..."
            handle_cancel_action
            return 1
        fi
        auth_code+="$line"
    done
    
    if [ -z "$auth_code" ]; then
        log "❌ 未输入授权码，Google Drive 配置取消"
        return 1
    fi
    
    # 解析授权码
    log "解析授权码..."
    
    # 提取关键字段
    local access_token=""
    local refresh_token=""
    local expiry=""
    
    # 使用简单的方法提取 JSON 字段
    access_token=$(echo "$auth_code" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
    refresh_token=$(echo "$auth_code" | grep -o '"refresh_token":"[^"]*"' | cut -d'"' -f4)
    expiry=$(echo "$auth_code" | grep -o '"expiry":"[^"]*"' | cut -d'"' -f4)
    
    if [ -z "$access_token" ] || [ -z "$refresh_token" ]; then
        log "❌ 无法解析授权码，请确保格式正确"
        return 1
    fi
    
    log "✅ 授权码解析成功"
    log "  Access Token: $(echo $access_token | cut -c1-20)..."
    log "  Refresh Token: $(echo $refresh_token | cut -c1-20)..."
    log "  Expiry: $expiry"
    
    # 配置远程名称
    read -p "请输入 Google Drive 远程配置名称 (默认: gdrive): " GDRIVE_REMOTE_NAME
    GDRIVE_REMOTE_NAME=${GDRIVE_REMOTE_NAME:-gdrive}
    
    # 检查并删除现有的 Google Drive 配置
    if [ -f "$RCLONE_CONFIG" ]; then
        # 检查是否有同名配置
        if grep -q "^\[$GDRIVE_REMOTE_NAME\]" "$RCLONE_CONFIG"; then
            log "⚠️ 发现已存在的 Google Drive 配置 '$GDRIVE_REMOTE_NAME'"
            read -p "是否删除现有的配置并重新创建？(y/N): " delete_confirm
            if [[ "$delete_confirm" =~ ^[Yy]$ ]]; then
                # 删除现有配置
                sed -i "/^\[$GDRIVE_REMOTE_NAME\]/,/^\[/ { /^\[$GDRIVE_REMOTE_NAME\]/d; /^\[/b; d }" "$RCLONE_CONFIG"
                log "✅ 已删除现有 Google Drive 配置"
            else
                log "❌ 用户取消，保留现有配置"
                return 1
            fi
        fi
    fi
    
    # 直接生成 rclone 配置
    log "🔧 生成 Google Drive Rclone 配置..."
    
    # 确保配置目录存在
    mkdir -p "$(dirname "$RCLONE_CONFIG")"
    
    # 生成完整的 rclone 配置
    cat >> "$RCLONE_CONFIG" << EOF

[$GDRIVE_REMOTE_NAME]
type = drive
scope = drive
token = $auth_code
team_drive = 

EOF
    
    log "✅ Google Drive Rclone 配置已创建"
    
    # 显示生成的配置
    log "📋 Rclone 配置内容:"
    sed -n "/^\[$GDRIVE_REMOTE_NAME\]/,/^\[/p" "$RCLONE_CONFIG" | while read line; do
        log "  $line"
    done
    
    # 测试连接
    log "测试 Google Drive 连接..."
    if rclone lsd "$GDRIVE_REMOTE_NAME:" &>/dev/null; then
        log "✅ Google Drive 连接测试成功"
        
        # 创建备份目录
        log "创建 Google Drive 备份目录: $REMOTE_BACKUP_DIR"
        if rclone mkdir "$GDRIVE_REMOTE_NAME:$REMOTE_BACKUP_DIR" 2>/dev/null; then
            log "✅ Google Drive 备份目录创建成功"
        else
            log "⚠️ Google Drive 备份目录可能已存在"
        fi
        
        # 保存配置
        save_config
        
        # 显示成功信息
        echo ""
        echo "=========================================================="
        echo "           Google Drive 配置完成                         "
        echo "=========================================================="
        echo "✅ 配置成功！"
        echo "🔗 远程名称: $GDRIVE_REMOTE_NAME"
        echo "📁 备份目录: $REMOTE_BACKUP_DIR"
        echo "🔑 Token 已保存"
        echo ""
        echo "💡 测试命令:"
        echo "   rclone lsd $GDRIVE_REMOTE_NAME:"
        echo "   rclone about $GDRIVE_REMOTE_NAME:"
        echo "=========================================================="
        
        return 0
    else
        log "❌ Google Drive 连接测试失败"
        
        # 显示配置内容用于调试
        echo ""
        echo "⚠️ 连接测试失败，当前配置内容:"
        sed -n "/^\[$GDRIVE_REMOTE_NAME\]/,/^\[/p" "$RCLONE_CONFIG"
        echo ""
        echo "💡 调试建议:"
        echo "1. 检查授权码格式是否正确"
        echo "2. 手动运行: rclone config"
        echo "3. 重新获取授权码"
        return 1
    fi
}

# 配置OneDrive备份（直接生成rclone配置版本）
configure_onedrive_backup() {
    echo ""
    echo "=========================================================="
    echo "             配置 Microsoft OneDrive 备份                 "
    echo "=========================================================="
    
    # 检查并安装Rclone
    if ! check_and_install_rclone; then
        log "❌ Rclone安装失败，无法配置OneDrive"
        return 1
    fi
    
    echo "🔄 OneDrive 配置需要先在 Windows 上获取授权码"
    echo ""
    echo "📋 在 Windows 上获取授权码的步骤:"
    echo "https://halo.dbhzj.top/archives/linux-xia-rcloneonedrive-huo-qu-token-shi-xian-zi-dong-shang-chuan"
    echo "=========================================================="
    echo "1. 以管理员身份打开 PowerShell"
    echo ""
    echo "2. 下载并安装 Rclone:"
    echo ""
    echo "   # 以管理员身份打开 PowerShell"
    echo ""
    echo "   # 1. 下载 rclone"
    echo "   Invoke-WebRequest -Uri \"https://downloads.rclone.org/rclone-current-windows-amd64.zip\" -OutFile \"\$env:TEMP\\rclone.zip\""
    echo ""
    echo "   # 2. 解压"
    echo "   Expand-Archive -Path \"\$env:TEMP\\rclone.zip\" -DestinationPath \"\$env:TEMP\\rclone\" -Force"
    echo ""
    echo "   # 3. 复制到程序目录"
    echo "   Copy-Item \"\$env:TEMP\\rclone\\rclone-*-windows-amd64\\rclone.exe\" \"C:\\Windows\\System32\\\""
    echo ""
    echo "   # 4. 验证安装"
    echo "   rclone version"
    echo ""
    echo "3. 获取 OneDrive 授权:"
    echo "   在 PowerShell 中输入:"
    echo "   rclone authorize \"onedrive\""
    echo ""
    echo "4. 按照提示操作:"
    echo "   - 浏览器会打开 Microsoft 登录页面"
    echo "   - 登录您的 Microsoft 账号"
    echo "   - 授权 Rclone 访问 OneDrive"
    echo "   - 完成后会得到类似下面的 JSON 格式 token:"
    echo ""
    echo "   {\"access_token\":\"ENbNTXOspDrmvS6Nl44zTYtuVDKzuJTgvrYJR2ExlKD/gSAkznN9NTCGTLp9+YQGOjNq1i8Q4lgFtHAw==\",\"token_type\":\"Bearer\",\"refresh_token\":\"M.C533_SN1.0.U.-Cgo1hP4YafuZVYfgndEFYORZcJ9iT57cvbhdORbqz8FdUyip77Wp3Sj4mMef1A5NrAD0cs4EA2uI8liS2FdMkPYEGgLg9k!Oe60e!mLom8cw9ztISOZijJw7VHdXb0px!II019b2rqSs!yJcbpLKo6r!3MGhUyjZIJ3ZEz4WfJ72NXkZVWDq*gVNR06zr*l9Mau!cunqM14LW57cbUMRHlOwzPphgRUn1RePXz!LmwsivIKDUgSfYzf0zkPSKu!CbMEFgZ7FX6MyHWjQzdlXN4F3KZWZdlGzgVl!GXFAUaxJEQj9W5x2iFtwXRYkqWFWB2vWKQRdOpTFvnvY9rDeYPMZzHZeUl1T*yoRoHBe7PBBkzMoW!PkyLk7a66xyIfTnA\$\$\",\"expiry\":\"2025-12-06T22:50:24.8689319+08:00\",\"expires_in\":3599}"
    echo ""
    echo "5. 复制整个 JSON 内容（包括花括号 {}）"
    echo "=========================================================="
    echo ""
    
    read -p "按回车键继续配置 OneDrive..." _
    
    # 配置远程名称
    read -p "请输入 OneDrive 远程配置名称 (默认: onedrive): " ONEDRIVE_REMOTE_NAME
    ONEDRIVE_REMOTE_NAME=${ONEDRIVE_REMOTE_NAME:-onedrive}
    
    # 配置文件夹名称
    read -p "请输入 OneDrive 备份文件夹名称 (默认: 我的备份): " ONEDRIVE_REMOTE_FOLDER
    ONEDRIVE_REMOTE_FOLDER=${ONEDRIVE_REMOTE_FOLDER:-我的备份}
    
    echo ""
    echo "📋 配置信息:"
    echo "  - 远程名称: $ONEDRIVE_REMOTE_NAME"
    echo "  - 备份文件夹: $ONEDRIVE_REMOTE_FOLDER"
    echo "  - Drive ID: $ONEDRIVE_DRIVE_ID (自动设置)"
    echo "  - Drive Type: $ONEDRIVE_DRIVE_TYPE (自动设置)"
    echo ""
    
    # 获取 JSON token
    echo "请粘贴从 Windows 获取的 JSON token (按 ESC 键取消):"
    echo "格式示例: {\"access_token\":\"...\",\"token_type\":\"Bearer\",\"refresh_token\":\"...\",\"expiry\":\"...\"}"
    echo ""
    
    local json_input=""
    while IFS= read -r line; do
        # 检查是否按ESC键
        if [[ $line =~ $'\e' ]]; then
            echo ""
            echo "ESC键检测到，取消输入..."
            handle_cancel_action
            return 1
        fi
        json_input+="$line"
    done
    
    if [ -z "$json_input" ]; then
        log "❌ 未输入 JSON token，OneDrive 配置取消"
        return 1
    fi
    
    # 解析 JSON token
    log "解析 JSON token..."
    
    # 提取关键字段
    local access_token=""
    local refresh_token=""
    local expiry=""
    
    # 使用简单的方法提取 JSON 字段
    access_token=$(echo "$json_input" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
    refresh_token=$(echo "$json_input" | grep -o '"refresh_token":"[^"]*"' | cut -d'"' -f4)
    expiry=$(echo "$json_input" | grep -o '"expiry":"[^"]*"' | cut -d'"' -f4)
    
    if [ -z "$access_token" ] || [ -z "$refresh_token" ]; then
        log "❌ 无法解析 JSON token，请确保格式正确"
        return 1
    fi
    
    log "✅ JSON token 解析成功"
    log "  Access Token: $(echo $access_token | cut -c1-20)..."
    log "  Refresh Token: $(echo $refresh_token | cut -c1-20)..."
    log "  Expiry: $expiry"
    
    # 检查并删除现有的 OneDrive 配置
    if [ -f "$RCLONE_CONFIG" ]; then
        # 检查是否有同名配置
        if grep -q "^\[$ONEDRIVE_REMOTE_NAME\]" "$RCLONE_CONFIG"; then
            log "⚠️ 发现已存在的 OneDrive 配置 '$ONEDRIVE_REMOTE_NAME'"
            read -p "是否删除现有的配置并重新创建？(y/N): " delete_confirm
            if [[ "$delete_confirm" =~ ^[Yy]$ ]]; then
                # 删除现有配置
                sed -i "/^\[$ONEDRIVE_REMOTE_NAME\]/,/^\[/ { /^\[$ONEDRIVE_REMOTE_NAME\]/d; /^\[/b; d }" "$RCLONE_CONFIG"
                log "✅ 已删除现有 OneDrive 配置"
            else
                log "❌ 用户取消，保留现有配置"
                return 1
            fi
        fi
    fi
    
    # 直接生成 rclone 配置
    log "🔧 生成 OneDrive Rclone 配置..."
    
    # 确保配置目录存在
    mkdir -p "$(dirname "$RCLONE_CONFIG")"
    
    # 生成完整的 rclone 配置
    cat >> "$RCLONE_CONFIG" << EOF

[$ONEDRIVE_REMOTE_NAME]
type = onedrive
client_id = 
client_secret = 
token = {"access_token":"$access_token","token_type":"Bearer","refresh_token":"$refresh_token","expiry":"$expiry"}
drive_id = $ONEDRIVE_DRIVE_ID
drive_type = $ONEDRIVE_DRIVE_TYPE

EOF
    
    log "✅ OneDrive Rclone 配置已创建"
    
    # 显示生成的配置
    log "📋 Rclone 配置内容:"
    sed -n "/^\[$ONEDRIVE_REMOTE_NAME\]/,/^\[/p" "$RCLONE_CONFIG" | while read line; do
        log "  $line"
    done
    
    # 测试连接
    log "测试 OneDrive 连接..."
    if test_onedrive_connection; then
        log "✅ OneDrive 连接测试成功"
        
        # 创建备份目录
        log "创建 OneDrive 备份目录: $ONEDRIVE_REMOTE_FOLDER"
        if rclone mkdir "$ONEDRIVE_REMOTE_NAME:$ONEDRIVE_REMOTE_FOLDER" 2>/dev/null; then
            log "✅ OneDrive 备份目录创建成功"
        else
            log "⚠️ OneDrive 备份目录可能已存在"
        fi
        
        # 保存配置
        save_config
        
        # 测试上传
        echo ""
        log "开始测试 OneDrive 上传功能..."
        test_cloud_upload "onedrive"
        
        return 0
    else
        log "❌ OneDrive 连接测试失败，请检查配置"
        echo ""
        echo "💡 调试建议:"
        echo "1. 手动运行: rclone config"
        echo "2. 检查远程: rclone lsd $ONEDRIVE_REMOTE_NAME:"
        echo "3. 查看配置: cat $RCLONE_CONFIG | grep -A10 \"^\[$ONEDRIVE_REMOTE_NAME\]\""
        return 1
    fi
}

# 测试OneDrive连接
test_onedrive_connection() {
    log "测试 OneDrive 连接..."
    
    # 测试基本连接
    if rclone about "$ONEDRIVE_REMOTE_NAME:" &>/dev/null; then
        log "✅ OneDrive 基本连接测试通过"
        return 0
    else
        log "❌ OneDrive 基本连接测试失败"
        return 1
    fi
}

# 测试云存储上传
test_cloud_upload() {
    local cloud_type="$1"
    local remote_name="${2:-$ONEDRIVE_REMOTE_NAME}"
    
    echo ""
    echo "=========================================================="
    echo "             测试 $cloud_type 上传功能                    "
    echo "=========================================================="
    
    # 创建测试文件
    local test_file="/tmp/test_upload_$(date +%s).txt"
    echo "这是 $cloud_type 上传测试文件" > "$test_file"
    echo "生成时间: $(date)" >> "$test_file"
    echo "文件大小: 1KB" >> "$test_file"
    echo "测试目的: 验证 $cloud_type 上传功能是否正常" >> "$test_file"
    
    log "创建测试文件: $test_file"
    
    # 根据云存储类型选择上传路径
    local remote_path=""
    case "$cloud_type" in
        "onedrive")
            remote_path="$remote_name:$ONEDRIVE_REMOTE_FOLDER/"
            ;;
        "google")
            remote_path="$remote_name:test_backup/"
            ;;
        "baidu")
            # 百度网盘使用bypy测试
            log "测试百度网盘上传..."
            test_bypy_upload
            return $?
            ;;
        *)
            remote_path="$remote_name:test_backup/"
            ;;
    esac
    
    if [ -n "$remote_path" ]; then
        log "开始上传测试文件到 $remote_path"
        log "使用进度条显示上传进度..."
        
        # 使用rclone copy命令，显示进度条
        rclone copy "$test_file" "$remote_path" \
            -P \
            --transfers=1 \
            --checkers=1 \
            --log-level=INFO
        
        local upload_result=$?
        
        if [ $upload_result -eq 0 ]; then
            log "✅ $cloud_type 上传测试成功"
            
            # 验证文件
            log "验证上传的文件..."
            local filename=$(basename "$test_file")
            if rclone lsl "$remote_path" --include "$filename" &>/dev/null; then
                log "✅ 文件验证成功"
                
                # 清理测试文件
                log "清理测试文件..."
                rclone delete "$remote_path" --include "$filename"
                rm -f "$test_file"
                
                return 0
            else
                log "⚠️ 文件验证失败"
                rm -f "$test_file"
                return 1
            fi
        else
            log "❌ $cloud_type 上传测试失败"
            rm -f "$test_file"
            return 1
        fi
    fi
    
    rm -f "$test_file"
    return 1
}

# 测试百度网盘上传
test_bypy_upload() {
    if ! command -v bypy-local &> /dev/null; then
        log "❌ bypy-local 命令未找到"
        return 1
    fi
    
    # 创建测试文件
    local test_file="/tmp/test_bypy_upload_$(date +%s).txt"
    echo "这是百度网盘上传测试文件" > "$test_file"
    echo "生成时间: $(date)" >> "$test_file"
    
    log "测试百度网盘上传..."
    
    # 上传测试文件
    local upload_result=$(bypy-local upload "$test_file" "$BYPY_CLOUD_DIR/" 2>&1)
    
    if echo "$upload_result" | grep -q "Success"; then
        log "✅ 百度网盘上传测试成功"
        
        # 清理测试文件
        rm -f "$test_file"
        
        # 尝试清理测试文件
        local filename=$(basename "$test_file")
        bypy-local delete "$BYPY_CLOUD_DIR/$filename" 2>/dev/null || true
        
        return 0
    else
        log "❌ 百度网盘上传测试失败"
        log "错误信息: $upload_result"
        rm -f "$test_file"
        return 1
    fi
}

# 安装和配置百度网盘bypy
install_and_configure_bypy() {
    echo ""
    echo "=========================================================="
    echo "              安装和配置百度网盘 (bypy)                   "
    echo "=========================================================="
    
    # 检查是否已安装bypy
    if command -v bypy &> /dev/null; then
        log "✅ bypy 已安装"
        BYPY_INSTALLED=true
    else
        log "📦 开始安装bypy..."
        
        # 安装依赖
        log "1. 安装系统依赖..."
        if command -v apt &> /dev/null; then
            apt update && apt install -y python3 python3-pip python3-venv curl wget git openssl
        elif command -v yum &> /dev/null; then
            yum -y install python3 python3-pip python3-venv curl wget git openssl
        fi
        
        # 创建虚拟环境
        log "2. 创建Python虚拟环境..."
        python3 -m venv ~/.bypy_venv
        
        # 激活虚拟环境并安装bypy
        log "3. 安装bypy..."
        source ~/.bypy_venv/bin/activate
        pip install --upgrade pip
        pip install bypy requests requests-toolbelt tqdm pycryptodome
        
        # 创建软链接
        ln -sf ~/.bypy_venv/bin/bypy /usr/local/bin/bypy-local
        BYPY_INSTALLED=true
        
        log "✅ bypy 安装完成"
    fi
    
    # 配置授权
    echo ""
    echo "=========================================================="
    echo "              百度网盘授权配置                           "
    echo "=========================================================="
    echo "请按以下步骤完成授权:"
    echo "1. 将在浏览器中打开百度网盘授权页面"
    echo "2. 登录您的百度账号"
    echo "3. 复制授权码"
    echo "4. 粘贴回终端"
    echo ""
    
    read -p "按回车键开始授权..." _
    
    # 执行授权
    log "开始百度网盘授权..."
    
    # 检查是否已有授权
    if [ -f "$BYPY_CONFIG_DIR/bypy.json" ]; then
        log "检测到已有授权文件"
        read -p "是否重新授权？(y/N): " reauth
        if [[ ! $reauth =~ ^[Yy]$ ]]; then
            log "✅ 使用现有授权"
        else
            # 执行授权命令
            log "请按照提示完成授权..."
            bypy-local info
        fi
    else
        # 执行授权命令
        log "请按照提示完成授权..."
        bypy-local info
    fi
    
    # 验证授权
    log "验证授权..."
    if bypy-local list > /dev/null 2>&1; then
        log "✅ 百度网盘授权成功！"
        
        # 显示基本信息
        echo ""
        bypy-local info | grep -E "(Used|Total|用户名)" || true
        
        # 创建备份目录
        log "创建备份目录: $BYPY_CLOUD_DIR"
        bypy-local mkdir "$BYPY_CLOUD_DIR"
        
        # 测试上传
        echo ""
        log "开始测试百度网盘上传功能..."
        test_bypy_upload
        
        if [ $? -eq 0 ]; then
            log "✅ 百度网盘配置完成并通过测试"
            return 0
        else
            log "⚠️ 百度网盘配置完成但测试失败"
            return 1
        fi
    else
        log "❌ 百度网盘授权失败，请重试"
        return 1
    fi
}

# 创建Rclone配置
create_rclone_config() {
    local name="$1"
    local host="$2"
    local port="$3"
    local path="$4"
    local user="$5"
    local auth_method="$6"
    local password="$7"
    local key_file="$8"
    
    log "创建Rclone配置: $name"
    
    # 确保Rclone配置目录存在
    mkdir -p "$(dirname "$RCLONE_CONFIG")"
    
    # 添加配置到rclone.conf
    cat >> "$RCLONE_CONFIG" << EOF

[$name]
type = sftp
host = $host
port = $port
user = $user
path = $path
EOF

    if [ "$auth_method" = "password" ]; then
        # 使用rclone obscure命令模糊化密码
        if command -v rclone &> /dev/null; then
            local obscured_password=$(rclone obscure "$password" 2>/dev/null)
            if [ $? -eq 0 ] && [ -n "$obscured_password" ]; then
                echo "pass = $obscured_password" >> "$RCLONE_CONFIG"
                log "✅ 密码已模糊化并保存"
            else
                echo "pass = $password" >> "$RCLONE_CONFIG"
                log "⚠️ 密码模糊化失败，以明文保存"
            fi
        else
            echo "pass = $password" >> "$RCLONE_CONFIG"
            log "⚠️ Rclone未安装，密码以明文保存"
        fi
    else
        echo "key_file = $key_file" >> "$RCLONE_CONFIG"
    fi
    
    # 添加完整的SFTP配置参数
    cat >> "$RCLONE_CONFIG" << EOF
ssh_use_agent = false
shell_type = unix
md5sum_command = md5sum
sha1sum_command = sha1sum
EOF
    
    # 添加SSH已知主机
    ssh-keyscan -p "$port" "$host" >> "$KNOWN_HOSTS_FILE" 2>/dev/null
    
    log "✅ Rclone配置已添加: $name"
    
    # 显示配置内容（隐藏密码）
    log "Rclone配置内容:"
    if [ "$auth_method" = "password" ]; then
        grep -v "pass =" "$RCLONE_CONFIG" | tail -10 | while read line; do
            log "  $line"
        done
        log "  pass = ***[已模糊化]***"
    else
        tail -10 "$RCLONE_CONFIG" | while read line; do
            log "  $line"
        done
    fi
}

# 发送邮件通知
send_email_notification() {
    local subject="$1"
    local message="$2"
    
    if [ -z "$RECEIVER_EMAIL" ] || [ -z "$SENDER_EMAIL" ]; then
        log "❌ 邮箱配置不完整，跳过邮件发送"
        return 1
    fi
    
    log "📧 发送邮件通知到: $RECEIVER_EMAIL"
    
    # 使用多种方式尝试发送邮件
    local success=false
    
    # 方式1: 使用 msmtp
    if command -v msmtp &> /dev/null && [ -f "/etc/msmtprc" ]; then
        local temp_mail="/tmp/backup_notify_$$.txt"
        echo -e "Subject: $subject\n\n$message" > "$temp_mail"
        
        if msmtp "$RECEIVER_EMAIL" < "$temp_mail" 2>/dev/null; then
            success=true
            log "✅ 邮件发送成功 (msmtp)"
        fi
        rm -f "$temp_mail"
    fi
    
    # 方式2: 使用 sendmail (备用)
    if [ "$success" = false ] && command -v sendmail &> /dev/null; then
        local temp_mail="/tmp/backup_notify_$$.txt"
        cat > "$temp_mail" << EOF
From: $SENDER_EMAIL
To: $RECEIVER_EMAIL
Subject: $subject

$message
EOF
        if sendmail -f "$SENDER_EMAIL" "$RECEIVER_EMAIL" < "$temp_mail" 2>/dev/null; then
            success=true
            log "✅ 邮件发送成功 (sendmail)"
        fi
        rm -f "$temp_mail"
    fi
    
    # 方式3: 使用 mail 命令 (备用)
    if [ "$success" = false ] && command -v mail &> /dev/null; then
        if echo "$message" | mail -s "$subject" -r "$SENDER_EMAIL" "$RECEIVER_EMAIL" 2>/dev/null; then
            success=true
            log "✅ 邮件发送成功 (mail)"
        fi
    fi
    
    if [ "$success" = true ]; then
        return 0
    else
        log "❌ 邮件发送失败"
        return 1
    fi
}

# 修复版发送Telegram通知 - 确保换行符正确处理
send_telegram_notification() {
    local message="$1"
    
    if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
        log "❌ Telegram配置不完整，跳过发送"
        return 1
    fi
    
    log "🤖 发送Telegram通知"
    
    # 构建完整的Telegram API URL
    local telegram_url="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
    
    # 使用curl发送请求，正确格式化参数
    # 使用-d参数确保换行符正确处理
    local response=$(curl -s -w "\n%{http_code}" -X POST "$telegram_url" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "chat_id=$TG_CHAT_ID" \
        -d "text=$(echo -e "$message")")
    
    # 分离响应内容和HTTP状态码
    local http_code=$(echo "$response" | tail -n1)
    local response_body=$(echo "$response" | head -n -1)
    
    if [ "$http_code" = "200" ]; then
        if echo "$response_body" | grep -q '"ok":true'; then
            log "✅ Telegram通知发送成功"
            return 0
        else
            log "❌ Telegram API返回错误: $response_body"
            return 1
        fi
    else
        log "❌ HTTP请求失败，状态码: $http_code"
        return 1
    fi
}

# 生成详细的备份状态报告（邮件格式）
generate_backup_status_report() {
    local backup_file="$1"
    local backup_size="$2"
    local total_time="$3"
    
    # 计算执行时间
    local hours=$((total_time / 3600))
    local minutes=$(( (total_time % 3600) / 60 ))
    local seconds=$((total_time % 60))
    local time_str=$(printf "%02d小时%02d分钟%02d秒" $hours $minutes $seconds)
    
    local report="🏠 RojoHome 备份系统通知\n\n"
    
    report+="🖥️ 设备名称: $HOSTNAME\n"
    report+="📅 备份时间: $(date '+%Y-%m-%d %H:%M:%S')\n"
    report+="📦 备份文件: $(basename "$backup_file")\n"
    report+="💾 文件大小: $backup_size\n"
    report+="⏱️ 执行时间: $time_str\n"
    report+="📁 远程目录: $REMOTE_BACKUP_DIR\n"
    report+="☁️  网盘目录: $BYPY_CLOUD_DIR\n"
    report+="🔧 备份方式: $BACKUP_METHOD\n"
    report+="🐳 Docker镜像备份: $DOCKER_IMAGE_BACKUP_MODE\n"
    report+="📅 备份保留天数: $RETENTION_DAYS 天\n"
    report+="⏰ 每日备份时间: $BACKUP_HOUR:$BACKUP_MINUTE\n\n"
    
    # 添加详细的备份状态列表
    report+="📋 详细备份状态:\n"
    
    # 本地备份状态
    if [[ "$BACKUP_METHOD" == *"local"* ]] || [ "$BACKUP_METHOD" = "both_remote" ] || [ "$BACKUP_METHOD" = "both_cloud" ] || [ "$BACKUP_METHOD" = "all" ]; then
        if [ "$LOCAL_BACKUP_STATUS" = "success" ]; then
            report+="  ✅ 本地备份: 备份成功\n"
        else
            report+="  ❌ 本地备份: 备份失败\n"
        fi
    fi
    
    # 远程备份状态
    if [ "$BACKUP_METHOD" = "remote" ] || [ "$BACKUP_METHOD" = "both_remote" ] || [ "$BACKUP_METHOD" = "all" ]; then
        local remote_index=1
        for remote_name in "${!REMOTE_BACKUP_STATUS[@]}"; do
            local remote_status="${REMOTE_BACKUP_STATUS[$remote_name]}"
            local remote_host=$(get_remote_host "$remote_name")
            
            if [ "$remote_status" = "success" ]; then
                report+="  ✅ 远程服务器($remote_host)-$remote_name: 备份成功\n"
            else
                report+="  ❌ 远程服务器($remote_host)-$remote_name: 备份失败\n"
            fi
            ((remote_index++))
        done
        
        # 如果没有远程备份配置
        if [ ${#REMOTE_BACKUP_STATUS[@]} -eq 0 ]; then
            report+="  ⚠️ 远程备份: 未配置远程服务器\n"
        fi
    fi
    
    # 网盘备份状态 - 改进：区分云存储类型
    if [ "$BACKUP_METHOD" = "cloud" ] || [ "$BACKUP_METHOD" = "both_cloud" ] || [ "$BACKUP_METHOD" = "all" ]; then
        if [ -n "$BACKUP_CLOUD_TYPES" ]; then
            IFS=',' read -ra cloud_types <<< "$BACKUP_CLOUD_TYPES"
            for cloud_type in "${cloud_types[@]}"; do
                local cloud_status="${CLOUD_BACKUP_STATUS[$cloud_type]}"
                if [ "$cloud_status" = "success" ]; then
                    report+="  ✅ 网盘备份($cloud_type): 备份成功\n"
                elif [ "$cloud_status" = "failed" ] || [ "$cloud_status" = "not_configured" ]; then
                    report+="  ❌ 网盘备份($cloud_type): 备份失败\n"
                elif [ "$cloud_status" = "warning" ]; then
                    report+="  ⚠️ 网盘备份($cloud_type): 备份警告\n"
                else
                    report+="  ❓ 网盘备份($cloud_type): 未执行\n"
                fi
            done
        else
            report+="  ⚠️ 网盘备份: 未配置网盘\n"
        fi
    fi
    
    report+="\n🔔 通知时间: $(date '+%Y-%m-%d %H:%M:%S')"
    
    echo "$report"
}

# 生成Telegram专用格式的报告（简洁格式）- 修复换行问题
generate_telegram_status_report() {
    local backup_file="$1"
    local backup_size="$2"
    local total_time="$3"
    
    # 计算执行时间
    local hours=$((total_time / 3600))
    local minutes=$(( (total_time % 3600) / 60 ))
    local seconds=$((total_time % 60))
    local time_str=$(printf "%02d小时%02d分钟%02d秒" $hours $minutes $seconds)
    
    local report="🏠 RojoHome 备份系统通知\n\n"
    
    report+="🖥️ 设备名称: $HOSTNAME\n"
    report+="📅 备份时间: $(date '+%Y-%m-%d %H:%M:%S')\n"
    report+="📦 备份文件: $(basename "$backup_file")\n"
    report+="💾 文件大小: $backup_size\n"
    report+="⏱️ 执行时间: $time_str\n"
    report+="📁 远程目录: $REMOTE_BACKUP_DIR\n"
    report+="☁️  网盘目录: $BYPY_CLOUD_DIR\n"
    report+="🔧 备份方式: $BACKUP_METHOD\n"
    report+="🐳 Docker镜像备份: $DOCKER_IMAGE_BACKUP_MODE\n"
    report+="📅 备份保留天数: $RETENTION_DAYS 天\n"
    report+="⏰ 每日备份时间: $BACKUP_HOUR:$BACKUP_MINUTE\n\n"
    
    # 添加详细的备份状态列表（Telegram专用格式）
    report+="📋 详细备份状态:\n"
    
    # 本地备份状态
    if [[ "$BACKUP_METHOD" == *"local"* ]] || [ "$BACKUP_METHOD" = "both_remote" ] || [ "$BACKUP_METHOD" = "both_cloud" ] || [ "$BACKUP_METHOD" = "all" ]; then
        if [ "$LOCAL_BACKUP_STATUS" = "success" ]; then
            report+="✅ 本地备份: 备份成功\n"
        else
            report+="❌ 本地备份: 备份失败\n"
        fi
    fi
    
    # 远程备份状态
    if [ "$BACKUP_METHOD" = "remote" ] || [ "$BACKUP_METHOD" = "both_remote" ] || [ "$BACKUP_METHOD" = "all" ]; then
        local remote_index=1
        for remote_name in "${!REMOTE_BACKUP_STATUS[@]}"; do
            local remote_status="${REMOTE_BACKUP_STATUS[$remote_name]}"
            local remote_host=$(get_remote_host "$remote_name")
            
            if [ "$remote_status" = "success" ]; then
                report+="✅ 远程服务器($remote_host)-${remote_name}: 备份成功\n"
            else
                report+="❌ 远程服务器($remote_host)-${remote_name}: 备份失败\n"
            fi
            ((remote_index++))
        done
        
        # 如果没有远程备份配置
        if [ ${#REMOTE_BACKUP_STATUS[@]} -eq 0 ]; then
            report+="⚠️ 远程备份: 未配置远程服务器\n"
        fi
    fi
    
    # 网盘备份状态 - 改进：区分云存储类型
    if [ "$BACKUP_METHOD" = "cloud" ] || [ "$BACKUP_METHOD" = "both_cloud" ] || [ "$BACKUP_METHOD" = "all" ]; then
        if [ -n "$BACKUP_CLOUD_TYPES" ]; then
            IFS=',' read -ra cloud_types <<< "$BACKUP_CLOUD_TYPES"
            for cloud_type in "${cloud_types[@]}"; do
                local cloud_status="${CLOUD_BACKUP_STATUS[$cloud_type]}"
                if [ "$cloud_status" = "success" ]; then
                    report+="✅ 网盘备份($cloud_type): 备份成功\n"
                elif [ "$cloud_status" = "failed" ] || [ "$cloud_status" = "not_configured" ]; then
                    report+="❌ 网盘备份($cloud_type): 备份失败\n"
                elif [ "$cloud_status" = "warning" ]; then
                    report+="⚠️ 网盘备份($cloud_type): 备份警告\n"
                else
                    report+="❓ 网盘备份($cloud_type): 未执行\n"
                fi
            done
        else
            report+="⚠️ 网盘备份: 未配置网盘\n"
        fi
    fi
    
    report+="\n🔔 通知时间: $(date '+%Y-%m-%d %H:%M:%S')"
    
    echo "$report"
}

# 发送备份完成通知
send_backup_notification() {
    local backup_file="$1"
    local backup_size="$2"
    local total_time="$3"
    
    local subject="📊 备份完成报告 - $HOSTNAME"
    
    # 根据配置的方法发送通知
    case "$NOTIFICATION_METHOD" in
        "email")
            local message=$(generate_backup_status_report "$backup_file" "$backup_size" "$total_time")
            send_email_notification "$subject" "$message"
            ;;
        "telegram")
            local message=$(generate_telegram_status_report "$backup_file" "$backup_size" "$total_time")
            send_telegram_notification "$message"
            ;;
        "both")
            local email_message=$(generate_backup_status_report "$backup_file" "$backup_size" "$total_time")
            local telegram_message=$(generate_telegram_status_report "$backup_file" "$backup_size" "$total_time")
            send_email_notification "$subject" "$email_message"
            send_telegram_notification "$telegram_message"
            ;;
        *)
            log "⏭️ 未配置通知方法，跳过发送"
            ;;
    esac
}

# 检查并安装Rclone
check_and_install_rclone() {
    log "🔍 检查 Rclone 安装状态..."
    
    # 检查是否已安装Rclone
    if command -v rclone &> /dev/null; then
        local current_version=$(rclone version | head -n1 | awk '{print $2}')
        log "✅ Rclone 已安装，版本: $current_version"
        return 0
    else
        log "❌ Rclone 未安装，开始自动安装..."
        
        # 安装依赖
        if command -v apt &> /dev/null; then
            apt update && apt install -y curl unzip
        elif command -v yum &> /dev/null; then
            yum -y install curl unzip
        fi
        
        # 使用官方安装脚本
        log "使用官方脚本安装 Rclone..."
        curl https://rclone.org/install.sh | sudo bash
        
        if command -v rclone &> /dev/null; then
            local installed_version=$(rclone version | head -n1 | awk '{print $2}')
            log "✅ Rclone 安装成功，版本: $installed_version"
            return 0
        else
            log "❌ Rclone 安装失败，跳过远程同步功能"
            return 1
        fi
    fi
}

# 改进的远程连接测试函数
test_remote_connection() {
    local remote_name="$1"
    
    log "测试远程连接: $remote_name"
    
    # 方法1: 使用 about 命令测试基本连接
    log "方法1: 测试基本连接..."
    if rclone about "$remote_name:" &>/dev/null; then
        log "✅ 基本连接测试通过"
        return 0
    fi
    
    # 方法2: 使用 lsd 命令测试目录列表
    log "方法2: 测试目录列表..."
    if rclone lsd "$remote_name:" &>/dev/null; then
        log "✅ 目录列表测试通过"
        return 0
    fi
    
    # 方法3: 使用更详细的错误信息
    log "方法3: 获取详细错误信息..."
    local error_output
    error_output=$(rclone lsd "$remote_name:" 2>&1)
    
    if [ $? -eq 0 ]; then
        log "✅ 连接测试通过"
        return 0
    else
        log "❌ 连接测试失败，错误信息: $error_output"
        return 1
    fi
}

# 检查现有Rclone配置
check_existing_rclone_config() {
    log "检查现有Rclone配置..."
    
    if [ -f "$RCLONE_CONFIG" ]; then
        log "找到Rclone配置文件: $RCLONE_CONFIG"
        
        # 显示已配置的远程存储
        if rclone listremotes &>/dev/null; then
            local remotes=$(rclone listremotes)
            log "已配置的远程存储:"
            echo "$remotes" | while read remote; do
                log "  - $remote"
            done
            return 0
        else
            log "❌ 无法读取Rclone配置"
            return 1
        fi
    else
        log "❌ Rclone配置文件不存在: $RCLONE_CONFIG"
        return 1
    fi
}

# 检查并创建远程目录
check_and_create_remote_dir() {
    local remote_name="$1"
    local remote_dir="$2"
    
    log "检查远程目录: $remote_name:$remote_dir"
    
    # 检查目录是否存在
    if rclone lsd "$remote_name:$remote_dir" &>/dev/null; then
        log "✅ 远程目录已存在: $remote_dir"
        return 0
    else
        log "⚠️ 远程目录不存在，尝试创建: $remote_dir"
        
        # 创建目录
        if rclone mkdir "$remote_name:$remote_dir"; then
            log "✅ 远程目录创建成功: $remote_dir"
            return 0
        else
            log "❌ 远程目录创建失败: $remote_dir"
            return 1
        fi
    fi
}

# 获取远程存储的完整路径和显示信息
get_remote_display_info() {
    local remote_name="$1"
    # 使用设备名称_backup作为远程目录
    echo "$REMOTE_BACKUP_DIR/"
}

# 获取远程存储的实际操作路径（用于rclone命令）
get_remote_operation_path() {
    local remote_name="$1"
    # 使用设备名称_backup作为远程目录
    echo "${remote_name}:$REMOTE_BACKUP_DIR/"
}

# ----------------------------------------------------------------
# 修复版校验函数 - 修改方法3为size-only校验
# ----------------------------------------------------------------
verify_backup_files() {
    local local_file="$1"
    local remote_name="$2"
    local display_path="$3"
    local filename=$(basename "$local_file")
    local operation_path=$(get_remote_operation_path "$remote_name")
    
    log "  🔍 开始综合文件校验流程..."
    log "  ⏳ 等待 5 秒以确保对象存储元数据一致性..." 
    sleep 5
    
    log "  📄 目标文件: $remote_name:$display_path$filename"

    # 方法1: 基础文件大小校验 (使用 lsl 而不是 json，更稳定)
    log "  方法1: 基础文件大小校验"
    local local_size=$(stat -c%s "$local_file" 2>/dev/null || du -b "$local_file" | cut -f1)
    
    # 使用 rclone lsl 获取精确字节数，第1列是大小
    local remote_size_output=$(rclone lsl "$operation_path" --include "$filename" 2>/dev/null)
    local remote_size=$(echo "$remote_size_output" | awk '{print $1}')

    if [ -n "$local_size" ] && [ -n "$remote_size" ] && [ "$local_size" -eq "$remote_size" ]; then
        log "    ✅ 基础大小校验通过 (本地: ${local_size} bytes, 远程: ${remote_size} bytes)"
        local size_check=true
    else
        log "    ❌ 基础大小校验失败 (本地: ${local_size} bytes, 远程: ${remote_size:-Unknown} bytes)"
        log "    ⚠️ 调试信息: rclone lsl 输出: '$remote_size_output'"
        local size_check=false
    fi
    
    # 方法2: MD5哈希校验
    log "  方法2: MD5哈希校验"
    local local_md5=$(md5sum "$local_file" | cut -d' ' -f1)
    
    # 尝试获取远程 MD5
    local remote_md5_output=$(rclone hashsum MD5 "$operation_path" --include "$filename" 2>/dev/null)
    local remote_md5=$(echo "$remote_md5_output" | awk '{print $1}')
    
    if [ -n "$remote_md5" ]; then
        log "    本地MD5: $local_md5"
        log "    远程MD5: $remote_md5"
        if [ "$local_md5" = "$remote_md5" ]; then
            log "    ✅ MD5哈希校验通过"
            local md5_check=true
        else
            log "    ❌ MD5哈希校验失败"
            local md5_check=false
        fi
    else
        log "    ⚠️ 远程存储不支持MD5或获取失败，跳过此项"
        local md5_check=false
    fi
    
    # 方法3: 使用 rclone check 仅校验文件大小 (size-only)
    log "  方法3: rclone check (仅校验文件大小)"
    if rclone check "$local_file" "$operation_path" --include "$filename" --one-way --size-only &>/dev/null; then
        log "    ✅ rclone check (size-only) 校验通过"
        local rclone_check=true
    else
        log "    ❌ rclone check (size-only) 校验失败"
        local rclone_check=false
    fi
    
    # 最终结果判定
    if [ "$size_check" = true ] || [ "$md5_check" = true ] || [ "$rclone_check" = true ]; then
        log "  🎉 校验通过：文件已安全传输到 $remote_name:$display_path$filename"
        return 0
    else
        log "  ❌ 严重错误：所有校验手段均失败，请检查远程连接或权限"
        return 1
    fi
}

# 百度网盘备份函数
backup_to_baidu_cloud() {
    log "☁️  开始备份到百度网盘..."
    
    if ! command -v bypy-local &> /dev/null; then
        log "❌ bypy-local 命令未找到，请先安装和配置百度网盘"
        CLOUD_BACKUP_STATUS["baidu"]="failed"
        return 1
    fi
    
    local local_file="$BACKUP_FILE"
    local filename=$(basename "$local_file")
    local remote_path="$BYPY_CLOUD_DIR/$filename"
    
    log "  本地文件: $local_file"
    log "  网盘路径: $remote_path"
    
    # 检查并创建目录
    log "  检查百度网盘目录..."
    if bypy-local list "$BYPY_CLOUD_DIR" &>/dev/null; then
        log "  ✅ 百度网盘目录已存在: $BYPY_CLOUD_DIR"
    else
        log "  创建百度网盘目录: $BYPY_CLOUD_DIR"
        if bypy-local mkdir "$BYPY_CLOUD_DIR"; then
            log "  ✅ 目录创建成功"
        else
            log "  ❌ 目录创建失败"
            CLOUD_BACKUP_STATUS["baidu"]="failed"
            return 1
        fi
    fi
    
    # 上传文件
    log "  开始上传到百度网盘..."
    log "  上传进度:"
    
    # bypy没有内置进度条，我们通过文件大小变化来模拟进度
    local start_time=$(date +%s)
    
    local upload_result=$(bypy-local upload "$local_file" "$remote_path" 2>&1)
    local upload_exit_code=$?
    
    local end_time=$(date +%s)
    local upload_time=$((end_time - start_time))
    
    if echo "$upload_result" | grep -q "Success" || [ $upload_exit_code -eq 0 ]; then
        log "  ✅ 百度网盘上传成功 (用时: ${upload_time}秒)"
        
        # 验证文件
        log "  验证百度网盘文件..."
        if bypy-local list "$BYPY_CLOUD_DIR" | grep -q "$filename"; then
            log "  ✅ 文件验证成功: $filename"
            CLOUD_BACKUP_STATUS["baidu"]="success"
            return 0
        else
            log "  ⚠️ 文件验证失败，但上传可能成功"
            CLOUD_BACKUP_STATUS["baidu"]="warning"
            return 0
        fi
    else
        log "  ❌ 百度网盘上传失败 (用时: ${upload_time}秒)"
        log "  错误信息: $upload_result"
        CLOUD_BACKUP_STATUS["baidu"]="failed"
        return 1
    fi
}

# Google Drive备份函数
backup_to_google_drive() {
    log "☁️  开始备份到 Google Drive..."
    
    if ! command -v rclone &> /dev/null; then
        log "❌ Rclone 未安装，无法备份到 Google Drive"
        CLOUD_BACKUP_STATUS["google"]="failed"
        return 1
    fi
    
    if [ -z "$GDRIVE_REMOTE_NAME" ]; then
        log "❌ Google Drive 远程名称未配置"
        CLOUD_BACKUP_STATUS["google"]="not_configured"
        return 1
    fi
    
    local local_file="$BACKUP_FILE"
    local filename=$(basename "$local_file")
    local remote_path="$GDRIVE_REMOTE_NAME:$REMOTE_BACKUP_DIR/$filename"
    
    log "  本地文件: $local_file"
    log "  Google Drive路径: $remote_path"
    log "  远程名称: $GDRIVE_REMOTE_NAME"
    log "  远程目录: $REMOTE_BACKUP_DIR"
    
    # 测试连接
    if ! test_google_drive_connection; then
        log "❌ Google Drive 连接测试失败"
        CLOUD_BACKUP_STATUS["google"]="failed"
        return 1
    fi
    
    # 检查并创建目录
    log "  检查 Google Drive 备份目录..."
    if ! check_and_create_remote_dir "$GDRIVE_REMOTE_NAME" "$REMOTE_BACKUP_DIR"; then
        log "❌ Google Drive 目录创建失败"
        CLOUD_BACKUP_STATUS["google"]="failed"
        return 1
    fi
    
    # 上传文件
    log "  开始上传到 Google Drive..."
    log "  上传进度:"
    local start_time=$(date +%s)
    
    # 使用进度条显示上传进度
    rclone copy "$local_file" "$GDRIVE_REMOTE_NAME:$REMOTE_BACKUP_DIR/" \
        -P \
        --transfers=$RCLONE_TRANSFERS \
        --multi-thread-streams=$RCLONE_STREAMS \
        --buffer-size=$RCLONE_BUFFER_SIZE \
        --checkers=$RCLONE_CHECKERS \
        --log-file=$LOG_FILE
    
    local upload_result=$?
    local end_time=$(date +%s)
    local upload_time=$((end_time - start_time))
    
    if [ $upload_result -eq 0 ]; then
        log "  ✅ Google Drive 上传成功 (用时: ${upload_time}秒)"
        
        # 验证文件
        log "  验证 Google Drive 文件..."
        if rclone lsl "$GDRIVE_REMOTE_NAME:$REMOTE_BACKUP_DIR/" --include "$filename" &>/dev/null; then
            log "  ✅ 文件验证成功: $filename"
            
            # 获取文件信息
            local file_info=$(rclone lsl "$GDRIVE_REMOTE_NAME:$REMOTE_BACKUP_DIR/" --include "$filename" 2>/dev/null)
            if [ -n "$file_info" ]; then
                log "  📊 Google Drive 文件信息: $file_info"
            fi
            
            # 清理旧备份
            log "  清理 Google Drive 旧备份 (保留天数: $RETENTION_DAYS 天)..."
            rclone delete "$GDRIVE_REMOTE_NAME:$REMOTE_BACKUP_DIR/" \
                --include "debian_backup_*.tar.gz" \
                --min-age ${RETENTION_DAYS}d \
                --log-file=$LOG_FILE
            
            CLOUD_BACKUP_STATUS["google"]="success"
            return 0
        else
            log "  ⚠️ 文件验证失败，但上传可能成功"
            CLOUD_BACKUP_STATUS["google"]="warning"
            return 0
        fi
    else
        log "  ❌ Google Drive 上传失败 (用时: ${upload_time}秒)"
        CLOUD_BACKUP_STATUS["google"]="failed"
        return 1
    fi
}

# 测试Google Drive连接
test_google_drive_connection() {
    if ! rclone lsd "$GDRIVE_REMOTE_NAME:" &>/dev/null; then
        return 1
    fi
    return 0
}

# OneDrive备份函数
backup_to_onedrive() {
    log "☁️  开始备份到 Microsoft OneDrive..."
    
    if ! command -v rclone &> /dev/null; then
        log "❌ Rclone 未安装，无法备份到 OneDrive"
        CLOUD_BACKUP_STATUS["onedrive"]="failed"
        return 1
    fi
    
    if [ -z "$ONEDRIVE_REMOTE_NAME" ] || [ -z "$ONEDRIVE_REMOTE_FOLDER" ]; then
        log "❌ OneDrive 配置不完整，请先配置 OneDrive"
        CLOUD_BACKUP_STATUS["onedrive"]="not_configured"
        return 1
    fi
    
    local local_file="$BACKUP_FILE"
    local filename=$(basename "$local_file")
    local remote_path="$ONEDRIVE_REMOTE_NAME:$ONEDRIVE_REMOTE_FOLDER/$filename"
    
    log "  本地文件: $local_file"
    log "  OneDrive路径: $remote_path"
    log "  远程名称: $ONEDRIVE_REMOTE_NAME"
    log "  备份目录: $ONEDRIVE_REMOTE_FOLDER"
    log "  Drive ID: $ONEDRIVE_DRIVE_ID"
    log "  Drive Type: $ONEDRIVE_DRIVE_TYPE"
    
    # 测试连接
    if ! test_remote_connection "$ONEDRIVE_REMOTE_NAME"; then
        log "❌ OneDrive 连接测试失败"
        CLOUD_BACKUP_STATUS["onedrive"]="failed"
        return 1
    fi
    
    # 检查并创建目录
    log "  检查 OneDrive 备份目录..."
    if ! check_and_create_remote_dir "$ONEDRIVE_REMOTE_NAME" "$ONEDRIVE_REMOTE_FOLDER"; then
        log "❌ OneDrive 目录创建失败"
        CLOUD_BACKUP_STATUS["onedrive"]="failed"
        return 1
    fi
    
    # 上传文件
    log "  开始上传到 OneDrive..."
    log "  上传进度:"
    local start_time=$(date +%s)
    
    # 使用进度条显示上传进度
    rclone copy "$local_file" "$ONEDRIVE_REMOTE_NAME:$ONEDRIVE_REMOTE_FOLDER/" \
        -P \
        --transfers=$RCLONE_TRANSFERS \
        --multi-thread-streams=$RCLONE_STREAMS \
        --buffer-size=$RCLONE_BUFFER_SIZE \
        --checkers=$RCLONE_CHECKERS \
        --log-file=$LOG_FILE
    
    local upload_result=$?
    local end_time=$(date +%s)
    local upload_time=$((end_time - start_time))
    
    if [ $upload_result -eq 0 ]; then
        log "  ✅ OneDrive 上传成功 (用时: ${upload_time}秒)"
        
        # 验证文件
        log "  验证 OneDrive 文件..."
        if rclone lsl "$ONEDRIVE_REMOTE_NAME:$ONEDRIVE_REMOTE_FOLDER/" --include "$filename" &>/dev/null; then
            log "  ✅ 文件验证成功: $filename"
            
            # 获取文件信息
            local file_info=$(rclone lsl "$ONEDRIVE_REMOTE_NAME:$ONEDRIVE_REMOTE_FOLDER/" --include "$filename" 2>/dev/null)
            if [ -n "$file_info" ]; then
                log "  📊 OneDrive 文件信息: $file_info"
            fi
            
            # 清理旧备份
            log "  清理 OneDrive 旧备份 (保留天数: $RETENTION_DAYS 天)..."
            rclone delete "$ONEDRIVE_REMOTE_NAME:$ONEDRIVE_REMOTE_FOLDER/" \
                --include "debian_backup_*.tar.gz" \
                --min-age ${RETENTION_DAYS}d \
                --log-file=$LOG_FILE
            
            CLOUD_BACKUP_STATUS["onedrive"]="success"
            return 0
        else
            log "  ⚠️ 文件验证失败，但上传可能成功"
            CLOUD_BACKUP_STATUS["onedrive"]="warning"
            return 0
        fi
    else
        log "  ❌ OneDrive 上传失败 (用时: ${upload_time}秒)"
        CLOUD_BACKUP_STATUS["onedrive"]="failed"
        return 1
    fi
}

# 备份到云存储（支持多网盘）
backup_to_cloud_storage() {
    log "☁️  开始云存储备份..."
    
    if [ -z "$BACKUP_CLOUD_TYPES" ]; then
        log "❌ 未配置云存储类型，跳过云存储备份"
        return 1
    fi
    
    IFS=',' read -ra cloud_types <<< "$BACKUP_CLOUD_TYPES"
    local success_count=0
    local total_count=${#cloud_types[@]}
    
    for cloud_type in "${cloud_types[@]}"; do
        echo ""
        log "=========================================="
        log "开始备份到 $cloud_type 网盘"
        log "=========================================="
        
        case "$cloud_type" in
            "baidu")
                if backup_to_baidu_cloud; then
                    ((success_count++))
                fi
                ;;
            "google")
                if backup_to_google_drive; then
                    ((success_count++))
                fi
                ;;
            "onedrive")
                if backup_to_onedrive; then
                    ((success_count++))
                fi
                ;;
            *)
                log "❌ 未知的云存储类型: $cloud_type"
                CLOUD_BACKUP_STATUS["unknown"]="failed"
                ;;
        esac
        
        log "=========================================="
        log "完成备份到 $cloud_type 网盘"
        log "=========================================="
        echo ""
    done
    
    log "📊 云存储备份统计:"
    log "  - 总网盘数量: $total_count"
    log "  - 成功备份: $success_count"
    log "  - 失败备份: $((total_count - success_count))"
    
    if [ $success_count -gt 0 ]; then
        return 0
    else
        return 1
    fi
}

# 自动备份到所有远程配置
backup_to_all_remotes() {
    log "🚀 开始自动备份到所有远程配置..."
    
    # 获取所有远程配置
    local remotes=$(rclone listremotes 2>/dev/null)
    if [ -z "$remotes" ]; then
        log "❌ 未找到任何远程配置，跳过远程备份"
        return 1
    fi
    
    local total_remotes=0
    local success_remotes=0
    local failed_remotes=0
    
    # 遍历所有远程配置
    while IFS= read -r remote; do
        if [ -n "$remote" ]; then
            ((total_remotes++))
            local remote_name=$(echo "$remote" | tr -d ':')
            local remote_host=$(get_remote_host "$remote_name")
            local display_path=$(get_remote_display_info "$remote_name")
            local operation_path=$(get_remote_operation_path "$remote_name")
            
            echo ""
            log "=========================================="
            log "开始备份到远程: $remote_name"
            log "服务器地址: $remote_host"
            log "远程存储路径: $display_path"
            log "操作路径: $operation_path"
            log "设备名称: $HOSTNAME"
            log "远程目录: $REMOTE_BACKUP_DIR"
            log "=========================================="
            
            # 测试连接
            if test_remote_connection "$remote_name"; then
                log "✅ 远程连接测试成功: $remote_name"
                
                # 检查并创建远程目录
                log "检查并创建远程目录: $REMOTE_BACKUP_DIR"
                if check_and_create_remote_dir "$remote_name" "$REMOTE_BACKUP_DIR"; then
                    log "✅ 远程目录准备就绪: $REMOTE_BACKUP_DIR"
                    
                    log "  上传备份文件到远程服务器..."
                    log "  本地文件: $BACKUP_FILE"
                    log "  远程位置: $operation_path"
                    log "  上传进度:"
                    
                    # 使用性能优化的参数同步备份文件，显示进度条
                    rclone copy "$BACKUP_FILE" "$operation_path" \
                        -P \
                        --transfers=$RCLONE_TRANSFERS \
                        --multi-thread-streams=$RCLONE_STREAMS \
                        --buffer-size=$RCLONE_BUFFER_SIZE \
                        --checkers=$RCLONE_CHECKERS \
                        --log-file=$LOG_FILE
                    
                    if [ $? -eq 0 ]; then
                        log "  ✅ 远程同步传输完成: $remote_name"
                        log "  文件已上传到: $operation_path$(basename $BACKUP_FILE)"
                        
                        # 调用修复后的校验函数
                        verify_backup_files "$BACKUP_FILE" "$remote_name" "$display_path"
                        local verify_result=$?
                        
                        if [ $verify_result -eq 0 ]; then
                            ((success_remotes++))
                            REMOTE_BACKUP_STATUS["$remote_name"]="success"
                            log "  ✅ 远程备份成功: $remote_name"
                        else
                            ((failed_remotes++))
                            REMOTE_BACKUP_STATUS["$remote_name"]="failed"
                            log "  ❌ 远程备份校验失败: $remote_name"
                        fi
                        
                        # 清理远程旧备份
                        log "  清理远程旧备份 (保留天数: $RETENTION_DAYS 天)..."
                        rclone delete "$operation_path" --include "debian_backup_*.tar.gz" --min-age ${RETENTION_DAYS}d --log-file=$LOG_FILE
                        
                        # 列出远程备份文件
                        log "  当前远程备份文件列表 ($operation_path):"
                        rclone lsl "$operation_path" --include "debian_backup_*.tar.gz" | while read line; do
                            log "    $line"
                        done
                    else
                        log "  ❌ 远程同步失败: $remote_name"
                        ((failed_remotes++))
                        REMOTE_BACKUP_STATUS["$remote_name"]="failed"
                    fi
                else
                    log "❌ 远程目录创建失败，跳过: $remote_name"
                    ((failed_remotes++))
                    REMOTE_BACKUP_STATUS["$remote_name"]="failed"
                fi
            else
                log "❌ 远程连接测试失败，跳过: $remote_name"
                ((failed_remotes++))
                REMOTE_BACKUP_STATUS["$remote_name"]="failed"
            fi
            
            log "=========================================="
            log "完成备份到远程: $remote_name"
            log "=========================================="
            echo ""
        fi
    done <<< "$remotes"
    
    # 输出远程备份统计
    log "📊 远程备份统计:"
    log "  - 总远程配置: $total_remotes"
    log "  - 成功备份: $success_remotes"
    log "  - 失败备份: $failed_remotes"
    
    if [ $success_remotes -gt 0 ]; then
        return 0
    else
        return 1
    fi
}

# 检测数据库应用
detect_databases() {
    log "🔍 检测系统中安装的数据库应用..."
    
    local detected_dbs=()
    
    # 检测 MySQL/MariaDB
    if command -v mysql &> /dev/null || command -v mysqld &> /dev/null || \
       systemctl is-active --quiet mysql 2>/dev/null || \
       systemctl is-active --quiet mariadb 2>/dev/null || \
       docker ps --format "table {{.Names}}" | grep -q -E "(mysql|mariadb)" 2>/dev/null; then
        detected_dbs+=("MySQL/MariaDB")
        log "  ✅ 检测到 MySQL/MariaDB"
    else
        MYSQL_BACKUP_ENABLED=false
        log "  ❌ 未检测到 MySQL/MariaDB"
    fi
    
    # 检测 PostgreSQL
    if command -v psql &> /dev/null || command -v postgres &> /dev/null || \
       systemctl is-active --quiet postgresql 2>/dev/null || \
       docker ps --format "table {{.Names}}" | grep -q -E "postgres" 2>/dev/null; then
        detected_dbs+=("PostgreSQL")
        log "  ✅ 检测到 PostgreSQL"
    else
        POSTGRES_BACKUP_ENABLED=false
        log "  ❌ 未检测到 PostgreSQL"
    fi
    
    # 检测 MongoDB
    if command -v mongod &> /dev/null || \
       systemctl is-active --quiet mongod 2>/dev/null || \
       docker ps --format "table {{.Names}}" | grep -q -E "mongo" 2>/dev/null; then
        detected_dbs+=("MongoDB")
        log "  ✅ 检测到 MongoDB"
    else
        MONGODB_BACKUP_ENABLED=false
        log "  ❌ 未检测到 MongoDB"
    fi
    
    # 检测 Redis
    if command -v redis-server &> /dev/null || \
       systemctl is-active --quiet redis 2>/dev/null || \
       docker ps --format "table {{.Names}}" | grep -q -E "redis" 2>/dev/null; then
        detected_dbs+=("Redis")
        log "  ✅ 检测到 Redis"
    else
        REDIS_BACKUP_ENABLED=false
        log "  ❌ 未检测到 Redis"
    fi
    
    if [ ${#detected_dbs[@]} -eq 0 ]; then
        log "  ⚠️ 未检测到任何数据库应用"
    else
        log "  📊 检测到的数据库: ${detected_dbs[*]}"
    fi
}

# 修复版MySQL备份函数
backup_mysql() {
    if [ "$MYSQL_BACKUP_ENABLED" != "true" ]; then
        log "  MySQL备份已禁用，跳过"
        return 0
    fi
    
    log "  开始备份MySQL数据库..."
    mkdir -p $BACKUP_DIR/databases/mysql
    
    local mysql_backup_success=false
    
    # 首先检查Docker容器中的MySQL
    local mysql_container=$(docker ps --format "table {{.Names}}" | grep -E "(mysql|mariadb)" | head -1)
    
    if [ -n "$mysql_container" ]; then
        log "  检测到Docker MySQL容器: $mysql_container"
        log "  方法1: 使用Docker容器备份MySQL..."
        
        # 从Docker容器备份
        if docker exec $mysql_container sh -c 'command -v mysqldump' &>/dev/null; then
            if docker exec $mysql_container mysqldump --all-databases --single-transaction --routines --triggers --events > $BACKUP_DIR/databases/mysql/all_databases.sql 2>/dev/null; then
                local sql_size=$(stat -c%s "$BACKUP_DIR/databases/mysql/all_databases.sql" 2>/dev/null || echo "0")
                if [ $sql_size -gt 1000 ]; then
                    gzip $BACKUP_DIR/databases/mysql/all_databases.sql
                    log "    ✅ Docker MySQL全库备份完成，文件大小: ${sql_size} bytes"
                    mysql_backup_success=true
                fi
            fi
        fi
        
        # 如果mysqldump失败，尝试备份数据目录
        if [ "$mysql_backup_success" = false ]; then
            log "  方法2: 备份Docker MySQL数据卷..."
            local volume_path=$(docker inspect $mysql_container --format '{{ range .Mounts }}{{ if eq .Destination "/var/lib/mysql" }}{{ .Source }}{{ end }}{{ end }}')
            if [ -n "$volume_path" ] && [ -d "$volume_path" ]; then
                if tar -czf $BACKUP_DIR/databases/mysql/mysql_data_dir.tar.gz -C "$volume_path" . 2>/dev/null; then
                    log "    ✅ Docker MySQL数据目录备份完成"
                    mysql_backup_success=true
                fi
            fi
        fi
    fi
    
    # 如果Docker方式失败，尝试系统安装的MySQL
    if [ "$mysql_backup_success" = false ] && command -v mysqldump &> /dev/null; then
        log "  方法3: 尝试系统MySQL备份..."
        
        # 尝试多种连接方式
        local mysql_attempts=(
            "sudo mysqldump --all-databases --single-transaction --routines --triggers --events"
            "mysqldump --all-databases --single-transaction --routines --triggers --events"
            "sudo mysqldump -u root --all-databases --single-transaction --routines --triggers --events"
            "mysqldump -u root --all-databases --single-transaction --routines --triggers --events"
        )
        
        # 尝试使用 debian-sys-maint 用户（Debian系统默认）
        if [ -f "/etc/mysql/debian.cnf" ]; then
            mysql_attempts+=("mysqldump --defaults-file=/etc/mysql/debian.cnf --all-databases --single-transaction --routines --triggers --events")
        fi
        
        for attempt in "${mysql_attempts[@]}"; do
            log "    尝试: $attempt"
            if $attempt > $BACKUP_DIR/databases/mysql/all_databases.sql 2>/dev/null; then
                local sql_size=$(stat -c%s "$BACKUP_DIR/databases/mysql/all_databases.sql" 2>/dev/null || echo "0")
                if [ $sql_size -gt 1000 ]; then
                    gzip $BACKUP_DIR/databases/mysql/all_databases.sql
                    log "    ✅ 系统MySQL全库备份完成，文件大小: ${sql_size} bytes"
                    mysql_backup_success=true
                    break
                else
                    rm -f $BACKUP_DIR/databases/mysql/all_databases.sql
                    log "    ⚠️ 备份文件过小，可能失败，尝试下一种方法"
                fi
            fi
        done
    fi
    
    # 最后尝试备份数据目录
    if [ "$mysql_backup_success" = false ] && [ -d "/var/lib/mysql" ]; then
        log "  方法4: 备份系统MySQL数据目录..."
        if tar -czf $BACKUP_DIR/databases/mysql/mysql_data_dir.tar.gz -C /var/lib mysql 2>/dev/null; then
            log "    ✅ 系统MySQL数据目录备份完成"
            mysql_backup_success=true
        fi
    fi
    
    if [ "$mysql_backup_success" = true ]; then
        log "  ✅ MySQL数据库备份流程完成"
    else
        log "  ⚠️ MySQL数据库备份失败，可能未安装或无法访问"
    fi
}

# 备份PostgreSQL数据库
backup_postgresql() {
    if [ "$POSTGRES_BACKUP_ENABLED" != "true" ]; then
        log "  PostgreSQL备份已禁用，跳过"
        return 0
    fi
    
    log "  开始备份PostgreSQL数据库..."
    mkdir -p $BACKUP_DIR/databases/postgresql
    
    local pgsql_backup_success=false
    
    # 首先检查Docker容器中的PostgreSQL
    local pgsql_container=$(docker ps --format "table {{.Names}}" | grep -E "postgres" | head -1)
    
    if [ -n "$pgsql_container" ]; then
        log "  检测到Docker PostgreSQL容器: $pgsql_container"
        log "  方法1: 使用Docker容器备份PostgreSQL..."
        
        if docker exec $pgsql_container sh -c 'command -v pg_dumpall' &>/dev/null; then
            if docker exec $pgsql_container pg_dumpall -U postgres > $BACKUP_DIR/databases/postgresql/all_databases.sql 2>/dev/null; then
                local sql_size=$(stat -c%s "$BACKUP_DIR/databases/postgresql/all_databases.sql" 2>/dev/null || echo "0")
                if [ $sql_size -gt 1000 ]; then
                    gzip $BACKUP_DIR/databases/postgresql/all_databases.sql
                    log "    ✅ Docker PostgreSQL全库备份完成，文件大小: ${sql_size} bytes"
                    pgsql_backup_success=true
                fi
            fi
        fi
    fi
    
    if [ "$pgsql_backup_success" = false ] && command -v pg_dumpall &> /dev/null; then
        if sudo -u postgres pg_dumpall > $BACKUP_DIR/databases/postgresql/all_databases.sql 2>/dev/null; then
            local sql_size=$(stat -c%s "$BACKUP_DIR/databases/postgresql/all_databases.sql" 2>/dev/null || echo "0")
            if [ $sql_size -gt 1000 ]; then
                gzip $BACKUP_DIR/databases/postgresql/all_databases.sql
                log "    ✅ PostgreSQL全库备份完成，文件大小: ${sql_size} bytes"
                pgsql_backup_success=true
            fi
        fi
    fi
    
    if [ "$pgsql_backup_success" = false ] && [ -d "/var/lib/postgresql" ]; then
        log "  方法2: 备份PostgreSQL数据目录..."
        if tar -czf $BACKUP_DIR/databases/postgresql/pgsql_data_dir.tar.gz -C /var/lib postgresql 2>/dev/null; then
            log "    ✅ PostgreSQL数据目录备份完成"
            pgsql_backup_success=true
        fi
    fi
    
    if [ "$pgsql_backup_success" = true ]; then
        log "  ✅ PostgreSQL数据库备份流程完成"
    else
        log "  ⚠️ PostgreSQL数据库备份失败，可能未安装或无法访问"
    fi
}

# 备份MongoDB数据库
backup_mongodb() {
    if [ "$MONGODB_BACKUP_ENABLED" != "true" ]; then
        log "  MongoDB备份已禁用，跳过"
        return 0
    fi
    
    log "  开始备份MongoDB数据库..."
    mkdir -p $BACKUP_DIR/databases/mongodb
    
    # 检查Docker容器中的MongoDB
    local mongo_container=$(docker ps --format "table {{.Names}}" | grep -E "mongo" | head -1)
    
    if [ -n "$mongo_container" ]; then
        log "  检测到Docker MongoDB容器: $mongo_container"
        log "  方法1: 使用Docker容器备份MongoDB..."
        
        if docker exec $mongo_container sh -c 'command -v mongodump' &>/dev/null; then
            if docker exec $mongo_container mongodump --out /tmp/mongodump 2>/dev/null; then
                docker cp $mongo_container:/tmp/mongodump $BACKUP_DIR/databases/mongodb/dump
                if [ $? -eq 0 ]; then
                    log "    ✅ Docker MongoDB数据备份完成"
                    return 0
                fi
            fi
        fi
    fi
    
    if command -v mongodump &> /dev/null; then
        if mongodump --out $BACKUP_DIR/databases/mongodb/dump 2>/dev/null; then
            log "    ✅ MongoDB数据备份完成"
        else
            log "    ❌ mongodump备份失败"
        fi
    elif [ -d "/var/lib/mongodb" ]; then
        tar -czf $BACKUP_DIR/databases/mongodb/mongodb_data_dir.tar.gz -C /var/lib mongodb 2>/dev/null && \
        log "    ✅ MongoDB数据目录备份完成"
    fi
    log "  ✅ MongoDB数据库备份流程完成"
}

# 备份Redis数据库
backup_redis() {
    if [ "$REDIS_BACKUP_ENABLED" != "true" ]; then
        log "  Redis备份已禁用，跳过"
        return 0
    fi
    
    log "  开始备份Redis数据库..."
    mkdir -p $BACKUP_DIR/databases/redis
    
    # 检查Docker容器中的Redis
    local redis_container=$(docker ps --format "table {{.Names}}" | grep -E "redis" | head -1)
    
    if [ -n "$redis_container" ]; then
        log "  检测到Docker Redis容器: $redis_container"
        log "  方法1: 备份Docker Redis数据..."
        
        # 获取Redis数据目录
        local redis_data_path=$(docker inspect $redis_container --format '{{ range .Mounts }}{{ if eq .Destination "/data" }}{{ .Source }}{{ end }}{{ end }}')
        if [ -n "$redis_data_path" ] && [ -d "$redis_data_path" ]; then
            tar -czf $BACKUP_DIR/databases/redis/redis_data_dir.tar.gz -C "$redis_data_path" . 2>/dev/null && \
            log "    ✅ Docker Redis数据目录备份完成"
        fi
        
        # 尝试执行SAVE命令
        docker exec $redis_container redis-cli SAVE 2>/dev/null
        local dump_file=$(docker exec $redis_container redis-cli CONFIG GET dir 2>/dev/null | grep -v dir | head -1)
        if [ -n "$dump_file" ]; then
            docker cp $redis_container:$dump_file/dump.rdb $BACKUP_DIR/databases/redis/dump.rdb 2>/dev/null && \
            log "    ✅ Docker Redis RDB文件备份完成"
        fi
    fi
    
    if [ -d "/var/lib/redis" ]; then
        tar -czf $BACKUP_DIR/databases/redis/redis_data_dir.tar.gz -C /var/lib redis 2>/dev/null && \
        log "    ✅ 系统Redis数据目录备份完成"
    fi
    
    if command -v redis-cli &> /dev/null && systemctl is-active --quiet redis 2>/dev/null; then
        redis-cli SAVE 2>/dev/null
        local dump_file=$(redis-cli CONFIG GET dir 2>/dev/null | grep -v dir | head -1)
        if [ -n "$dump_file" ] && [ -f "$dump_file/dump.rdb" ]; then
            cp "$dump_file/dump.rdb" $BACKUP_DIR/databases/redis/dump.rdb 2>/dev/null && \
            log "    ✅ 系统Redis RDB文件备份完成"
        fi
    fi
    log "  ✅ Redis数据库备份流程完成"
}

# 完整Docker备份函数（根据用户选择备份镜像）
backup_docker_complete() {
    log "🐳 开始完整Docker备份..."
    mkdir -p $BACKUP_DIR/docker
    
    if ! command -v docker &> /dev/null; then
        log "  ❌ Docker 未安装，跳过Docker备份"
        return 1
    fi
    
    # 1. 备份所有容器信息
    log "  1. 备份容器信息..."
    docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Command}}\t{{.Ports}}\t{{.Status}}" > $BACKUP_DIR/docker/containers.txt
    docker ps -a --no-trunc > $BACKUP_DIR/docker/containers_detailed.txt
    
    # 2. 备份所有容器配置（用于完整恢复）
    log "  2. 备份容器完整配置..."
    docker ps -aq | while read container_id; do
        container_name=$(docker inspect --format='{{.Name}}' $container_id | sed 's/^\///')
        log "    备份容器: $container_name"
        
        # 备份完整inspect信息
        docker inspect $container_id > $BACKUP_DIR/docker/${container_name}_inspect.json 2>/dev/null
        
        # 备份容器创建命令（用于恢复）
        docker inspect --format='{{.Config.Cmd}}' $container_id > $BACKUP_DIR/docker/${container_name}_cmd.txt 2>/dev/null
        docker inspect --format='{{.Config.Entrypoint}}' $container_id > $BACKUP_DIR/docker/${container_name}_entrypoint.txt 2>/dev/null
        docker inspect --format='{{.Config.Env}}' $container_id > $BACKUP_DIR/docker/${container_name}_env.txt 2>/dev/null
        docker inspect --format='{{.HostConfig}}' $container_id > $BACKUP_DIR/docker/${container_name}_hostconfig.json 2>/dev/null
        docker inspect --format='{{.Mounts}}' $container_id > $BACKUP_DIR/docker/${container_name}_mounts.json 2>/dev/null
        docker inspect --format='{{.NetworkSettings}}' $container_id > $BACKUP_DIR/docker/${container_name}_network.json 2>/dev/null
    done
    
    # 3. 备份所有镜像信息
    log "  3. 备份镜像信息..."
    docker images --all --digests > $BACKUP_DIR/docker/images_list.txt
    docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.CreatedAt}}\t{{.Size}}" > $BACKUP_DIR/docker/images_detailed.txt
    
    # 4. 根据用户选择备份镜像
    log "  4. 根据用户选择备份Docker镜像 (模式: $DOCKER_IMAGE_BACKUP_MODE)"
    case "$DOCKER_IMAGE_BACKUP_MODE" in
        "none")
            log "    ⏭️ 跳过镜像备份 (用户选择不备份镜像)"
            ;;
        "running")
            log "    🐳 备份运行中容器对应的镜像..."
            mkdir -p $BACKUP_DIR/docker/images
            # 获取所有运行中容器使用的镜像
            running_images=$(docker ps --format "{{.Image}}" | sort -u)
            
            if [ -n "$running_images" ]; then
                for image in $running_images; do
                    safe_name=$(echo $image | tr '/:' '_')
                    log "      保存运行中容器镜像: $image"
                    if docker save $image -o $BACKUP_DIR/docker/images/${safe_name}.tar 2>/dev/null; then
                        image_size=$(du -h $BACKUP_DIR/docker/images/${safe_name}.tar | cut -f1)
                        log "        ✅ 镜像保存成功: ${safe_name}.tar (${image_size})"
                    else
                        log "        ❌ 镜像保存失败: $image"
                    fi
                done
                log "      ✅ 运行中容器镜像备份完成，共备份 $(echo "$running_images" | wc -l) 个镜像"
            else
                log "      ⚠️ 没有运行中的容器，跳过镜像备份"
            fi
            ;;
        "all")
            log "    🐳 备份所有已拉取的镜像..."
            mkdir -p $BACKUP_DIR/docker/images
            # 获取所有镜像
            all_images=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -v "<none>" | sort -u)
            
            if [ -n "$all_images" ]; then
                for image in $all_images; do
                    safe_name=$(echo $image | tr '/:' '_')
                    log "      保存镜像: $image"
                    if docker save $image -o $BACKUP_DIR/docker/images/${safe_name}.tar 2>/dev/null; then
                        image_size=$(du -h $BACKUP_DIR/docker/images/${safe_name}.tar | cut -f1)
                        log "        ✅ 镜像保存成功: ${safe_name}.tar (${image_size})"
                    else
                        log "        ❌ 镜像保存失败: $image"
                    fi
                done
                log "      ✅ 所有镜像备份完成，共备份 $(echo "$all_images" | wc -l) 个镜像"
            else
                log "      ⚠️ 没有找到任何镜像，跳过镜像备份"
            fi
            ;;
        "list")
            log "    📝 只备份镜像名称和版本号..."
            # 创建镜像列表文件
            docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.CreatedAt}}\t{{.Size}}" > $BACKUP_DIR/docker/images_backup_list.txt
            log "      ✅ 镜像列表备份完成: images_backup_list.txt"
            ;;
        *)
            log "    ⚠️ 未知的镜像备份模式: $DOCKER_IMAGE_BACKUP_MODE，跳过镜像备份"
            ;;
    esac
    
    # 5. 备份Docker网络配置
    log "  5. 备份网络配置..."
    docker network ls > $BACKUP_DIR/docker/networks.txt
    docker network ls -q | while read network_id; do
        network_name=$(docker network inspect --format='{{.Name}}' $network_id)
        docker network inspect $network_id > $BACKUP_DIR/docker/network_${network_name}.json 2>/dev/null
    done
    
    # 6. 备份Docker卷信息
    log "  6. 备份卷信息..."
    docker volume ls -q > $BACKUP_DIR/docker/volumes_list.txt
    docker volume ls -q | while read volume_name; do
        docker volume inspect $volume_name > $BACKUP_DIR/docker/volume_${volume_name}.json 2>/dev/null
    done
    
    # 7. 备份Docker Compose文件（如果存在）
    log "  7. 查找Docker Compose文件..."
    find /home /root /opt /var/lib -name "docker-compose.yml" -o -name "docker-compose.yaml" 2>/dev/null | while read compose_file; do
        dir_name=$(dirname "$compose_file" | sed 's/^\///' | tr '/' '_')
        cp "$compose_file" $BACKUP_DIR/docker/compose_${dir_name}.yml 2>/dev/null
    done
    
    # 8. 生成恢复脚本
    log "  8. 生成Docker恢复脚本..."
    cat > $BACKUP_DIR/docker/restore_docker.sh << 'EOF'
#!/bin/bash
# Docker恢复脚本
# 用法: ./restore_docker.sh

echo "=========================================="
echo "          Docker 环境恢复脚本             "
echo "=========================================="
echo "开始恢复Docker环境..."

# 恢复镜像（如果存在）
if [ -d "./images" ]; then
    echo "恢复Docker镜像..."
    for image_file in ./images/*.tar; do
        if [ -f "$image_file" ]; then
            echo "加载镜像: $image_file"
            docker load -i "$image_file"
            if [ $? -eq 0 ]; then
                echo "✅ 镜像加载成功: $image_file"
            else
                echo "❌ 镜像加载失败: $image_file"
            fi
        fi
    done
else
    echo "⚠️ 未找到镜像备份目录，跳过镜像恢复"
    echo "💡 提示: 如果备份时选择了'只备份镜像列表'，请根据 images_backup_list.txt 手动拉取镜像"
fi

# 恢复网络
echo "恢复Docker网络..."
for network_file in ./network_*.json; do
    if [ -f "$network_file" ]; then
        network_name=$(echo "$network_file" | sed 's/\.\/network_//' | sed 's/\.json//')
        echo "恢复网络: $network_name"
        # 注意：网络恢复可能需要特殊处理，这里只是示例
        echo "⚠️  需要手动恢复网络: $network_name (参考 $network_file)"
    fi
done

# 恢复卷
echo "恢复Docker卷..."
for volume_file in ./volume_*.json; do
    if [ -f "$volume_file" ]; then
        volume_name=$(echo "$volume_file" | sed 's/\.\/volume_//' | sed 's/\.json//')
        echo "恢复卷: $volume_name"
        docker volume create --name "$volume_name" 2>/dev/null || echo "⚠️  卷已存在或创建失败: $volume_name"
    fi
done

echo ""
echo "=========================================="
echo "          Docker 恢复完成                 "
echo "=========================================="
echo "📋 后续步骤:"
echo "1. 检查镜像是否全部加载成功"
echo "2. 根据 containers.txt 和 *_inspect.json 文件重新创建容器"
echo "3. 参考 compose_*.yml 文件恢复Docker Compose服务"
echo "4. 检查网络和卷配置"
echo ""
echo "💡 提示: 可以使用以下命令查看备份的容器信息:"
echo "   cat containers.txt"
echo "   cat images_list.txt"
echo "=========================================="
EOF
    
    chmod +x $BACKUP_DIR/docker/restore_docker.sh
    
    log "  ✅ 完整Docker备份完成 (镜像备份模式: $DOCKER_IMAGE_BACKUP_MODE)"
}

# 倒计时函数
countdown_timer() {
    local seconds=$1
    echo ""
    echo "⏰ 系统将在 $seconds 秒后自动开始备份..."
    echo "按 ESC 键可以取消备份"
    echo ""
    
    for ((i=seconds; i>=1; i--)); do
        printf "\r倒计时: %02d 秒" $i
        # 检测ESC键
        read -t 1 -n 1 key
        if [[ $key = $'\e' ]]; then
            echo ""
            echo "ESC键检测到，取消备份..."
            handle_cancel_action
            exit 0
        fi
    done
    echo ""
    echo ""
    echo "=========================================================="
    echo "                   开始执行备份                           "
    echo "=========================================================="
    echo ""
}

# 🚀 主程序开始
show_logo
log "🚀 RojoHome备份系统启动 - 备份文件: $BACKUP_FILE"

# 读取现有配置
read_config

# 判断是否是首次运行
if [ ! -f "$CONFIG_FILE" ] || [ -z "$NOTIFICATION_METHOD" ] || [ -z "$BACKUP_METHOD" ] || [ -z "$DOCKER_IMAGE_BACKUP_MODE" ]; then
    # 首次运行配置模式
    echo ""
    echo "=========================================================="
    echo "                   首次运行配置                           "
    echo "=========================================================="
    
    # 首先配置备份计划
    configure_backup_schedule
    
    # 然后配置其他选项
    configure_notification
    configure_backup_method
    configure_docker_image_backup
    
    # 显示备份计划配置摘要
    show_backup_plan_summary
    
    # 保存配置
    save_config
    
    # 倒计时10秒后自动开始备份
    countdown_timer 10
    
else
    # 配置文件存在，直接使用配置
    log "📁 使用现有配置文件: $CONFIG_FILE"
    log "🔧 备份方式: $BACKUP_METHOD"
    log "☁️  网盘类型: $BACKUP_CLOUD_TYPES"
    log "🐳 Docker镜像备份: $DOCKER_IMAGE_BACKUP_MODE"
    log "🔔 通知方式: $NOTIFICATION_METHOD"
    log "📅 保留天数: $RETENTION_DAYS 天"
    log "⏰ 备份时间: $BACKUP_HOUR:$BACKUP_MINUTE"
    
    # 检查备份通知配置，如果按ESC重新配置
    if [ "$Backup_notification" = "0" ] || [ -z "$Backup_notification" ]; then
        echo ""
        echo "=========================================================="
        echo "          检测到未配置备份通知方法                        "
        echo "=========================================================="
        
        # 5秒倒计时，允许用户按ESC重新配置
        if ! countdown_with_esc 5 "5秒后自动进入备份（按ESC重新配置通知方法）" "configure_notification"; then
            log "用户选择重新配置通知方法"
            configure_notification
        fi
    fi
    
    # 检查备份方式配置，如果只有本地备份，提醒用户
    if [ "$BACKUP_METHOD" = "local" ]; then
        echo ""
        echo "=========================================================="
        echo "                    警告                               "
        echo "=========================================================="
        echo "当前配置为仅本地备份！"
        echo "仅有本地备份存在风险，建议配置远程备份。"
        echo ""
        
        # 检查是否有远程配置
        if [ -f "$RCLONE_CONFIG" ] && rclone listremotes &>/dev/null; then
            local existing_remotes=$(rclone listremotes)
            if [ -z "$existing_remotes" ]; then
                # 5秒倒计时，允许用户按ESC重新配置
                if ! countdown_with_esc 5 "5秒后自动继续（按ESC配置远程备份）" "configure_remote_backup"; then
                    log "用户选择配置远程备份"
                    configure_remote_backup
                fi
            fi
        else
            # 5秒倒计时，允许用户按ESC重新配置
            if ! countdown_with_esc 5 "5秒后自动继续（按ESC配置远程备份）" "configure_remote_backup"; then
                log "用户选择配置远程备份"
                configure_remote_backup
            fi
        fi
    fi
    
    # 显示简要配置信息
    echo ""
    echo "=========================================================="
    echo "                使用现有配置进行备份                     "
    echo "=========================================================="
    echo "📁 本地备份存储路径: $BACKUP_BASE"
    echo "📅 备份保留天数: $RETENTION_DAYS天"
    echo "⏰ 每日备份时间: $BACKUP_HOUR:$BACKUP_MINUTE"
    echo "📡 远程备份存储路径: $REMOTE_BACKUP_DIR/"
    if [ -n "$BACKUP_CLOUD_TYPES" ]; then
        echo "☁️  网盘备份类型: $BACKUP_CLOUD_TYPES"
    else
        echo "☁️  网盘备份类型: 未配置"
    fi
    echo "🔔 通知方式: $NOTIFICATION_METHOD"
    echo "🐳 Docker镜像备份: $DOCKER_IMAGE_BACKUP_MODE"
    echo "=========================================================="
    
    # 倒计时3秒后自动开始备份
    countdown_timer 3
fi

# 1. Rclone 智能检测和安装
log "1. 检查 Rclone 状态..."
if check_and_install_rclone; then
    log "✅ Rclone 检查完成，继续备份流程"
else
    log "⚠️ Rclone 检查或安装有问题，但继续备份流程"
fi

# 2. 备份系统信息
log "2. 备份系统信息..."
mkdir -p $BACKUP_DIR/system
cat /etc/os-release > $BACKUP_DIR/system/os_release.txt
uname -a > $BACKUP_DIR/system/kernel_info.txt
df -h > $BACKUP_DIR/system/disk_usage.txt
ip addr show > $BACKUP_DIR/system/network_info.txt
cat /proc/cpuinfo > $BACKUP_DIR/system/cpu_info.txt
free -h > $BACKUP_DIR/system/memory_info.txt
log "✅ 系统信息备份完成"

# 3. 完整Docker备份
log "3. 完整Docker备份..."
backup_docker_complete

# 4. 备份 Docker 数据卷
log "4. 备份 Docker 数据卷..."
mkdir -p $BACKUP_DIR/docker_volumes
if command -v docker &> /dev/null; then
    docker volume ls -q | while read volume_name; do
        if [ ! -z "$volume_name" ]; then
            log "  备份数据卷: $volume_name"
            docker run --rm -v $volume_name:/source -v $BACKUP_DIR/docker_volumes:/backup alpine \
                tar -czf /backup/${volume_name}.tar.gz -C /source ./ 2>/dev/null
        fi
    done
    log "✅ Docker数据卷备份完成"
fi

# 5. 备份网站数据
log "5. 备份网站数据..."
mkdir -p $BACKUP_DIR/websites
website_dirs=("/var/www" "/home" "/opt" "/srv")
for dir in "${website_dirs[@]}"; do
    if [ -d "$dir" ] && [ "$(ls -A $dir 2>/dev/null)" ]; then
        log "  备份网站目录: $dir"
        safe_name=$(echo $dir | sed 's/^\///' | tr '/' '_')
        tar -czf $BACKUP_DIR/websites/${safe_name}.tar.gz -C $(dirname $dir) $(basename $dir) 2>/dev/null
    fi
done
log "✅ 网站数据备份完成"

# 6. 备份 Web 服务器配置
log "6. 备份 Web 服务器配置..."
mkdir -p $BACKUP_DIR/configs
if [ -d "/etc/nginx" ]; then
    tar -czf $BACKUP_DIR/configs/nginx.tar.gz -C /etc nginx 2>/dev/null && log "    ✅ Nginx配置备份完成"
fi
if [ -d "/etc/apache2" ]; then
    tar -czf $BACKUP_DIR/configs/apache.tar.gz -C /etc apache2 2>/dev/null && log "    ✅ Apache配置备份完成"
fi
log "✅ Web服务器配置备份完成"

# 7. 检测数据库应用
detect_databases

# 8. 备份数据库
log "8. 备份数据库..."
mkdir -p $BACKUP_DIR/databases
backup_mysql
backup_postgresql
backup_mongodb
backup_redis
log "✅ 数据库备份完成"

# 9. 备份 SSL 证书
log "9. 备份 SSL 证书..."
mkdir -p $BACKUP_DIR/ssl
if [ -d "/etc/letsencrypt" ]; then
    tar -czf $BACKUP_DIR/ssl/letsencrypt.tar.gz -C /etc letsencrypt 2>/dev/null && log "    ✅ Let's Encrypt备份完成"
fi
if [ -d "/etc/ssl" ]; then
    tar -czf $BACKUP_DIR/ssl/ssl_certs.tar.gz -C /etc ssl 2>/dev/null && log "    ✅ SSL证书备份完成"
fi
log "✅ SSL证书备份完成"

# 10. 备份系统服务配置
log "10. 备份系统服务配置..."
if [ -d "/etc/systemd/system" ]; then
    tar -czf $BACKUP_DIR/configs/systemd_services.tar.gz -C /etc systemd/system 2>/dev/null && log "  ✅ 系统服务备份完成"
fi

# 11. 备份重要配置文件
log "11. 备份重要配置文件..."
mkdir -p $BACKUP_DIR/etc
important_files=("/etc/fstab" "/etc/hosts" "/etc/passwd" "/etc/group" "/etc/crontab" "/etc/resolv.conf" "/etc/hostname")
for file in "${important_files[@]}"; do
    if [ -f "$file" ]; then
        cp "$file" $BACKUP_DIR/etc/ 2>/dev/null
    fi
done

# 备份软件源列表
if [ -d "/etc/apt/sources.list.d" ]; then
    cp -r /etc/apt/sources.list.d $BACKUP_DIR/etc/ 2>/dev/null
    cp /etc/apt/sources.list $BACKUP_DIR/etc/ 2>/dev/null
fi

# 备份安装的软件包列表
if command -v dpkg &> /dev/null; then
    dpkg --get-selections > $BACKUP_DIR/etc/installed_packages.txt 2>/dev/null
fi

log "✅ 重要配置文件备份完成"

# 12. 备份用户数据
log "12. 备份用户数据..."
mkdir -p $BACKUP_DIR/users
cat /etc/passwd > $BACKUP_DIR/users/passwd_backup.txt
cat /etc/group > $BACKUP_DIR/users/group_backup.txt
cat /etc/shadow > $BACKUP_DIR/users/shadow_backup.txt 2>/dev/null || log "    ⚠️ 无法备份shadow文件"
log "✅ 用户数据备份完成"

# 13. 创建备份清单和恢复指南
log "13. 创建备份清单和恢复指南..."
ls -la $BACKUP_DIR/ > $BACKUP_DIR/backup_manifest.txt

# 创建主恢复脚本
cat > $BACKUP_DIR/hostrecover.sh << 'EOF'
#!/bin/bash
# RojoHome 系统完整恢复脚本
# 用法: ./hostrecover.sh

echo "=========================================================="
echo "              RojoHome 系统完整恢复脚本                   "
echo "=========================================================="
echo "重要提示: 请在恢复前仔细阅读以下说明"
echo ""

# 检查是否以root用户运行
if [ "$EUID" -ne 0 ]; then
    echo "❌ 请使用 root 用户运行此脚本: sudo ./hostrecover.sh"
    exit 1
fi

echo "📋 恢复步骤概述:"
echo "1. 系统环境检查"
echo "2. 解压备份文件"
echo "3. 恢复系统配置"
echo "4. 恢复用户数据"
echo "5. 恢复Docker环境"
echo "6. 恢复网站数据"
echo "7. 恢复数据库"
echo "8. 恢复SSL证书"
echo "9. 恢复网盘配置（如果配置了）"
echo ""

read -p "是否继续恢复? (y/N): " confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "恢复已取消"
    exit 0
fi

# 解压备份文件
echo "解压备份文件..."
tar -xzf debian_backup_*.tar.gz

if [ $? -ne 0 ]; then
    echo "❌ 解压失败，请检查备份文件"
    exit 1
fi

echo "✅ 解压完成"

# 恢复系统配置
echo "恢复系统配置..."
if [ -d "etc" ]; then
    cp -r etc/* /etc/ 2>/dev/null
    echo "✅ 系统配置恢复完成"
else
    echo "⚠️ 未找到系统配置备份"
fi

# 恢复用户数据
echo "恢复用户数据..."
if [ -f "users/passwd_backup.txt" ]; then
    # 注意: 用户数据恢复需要谨慎操作
    echo "⚠️ 用户数据恢复需要手动操作，请参考 users/ 目录下的备份文件"
else
    echo "⚠️ 未找到用户数据备份"
fi

# 恢复Docker环境
echo "恢复Docker环境..."
if [ -d "docker" ] && [ -f "docker/restore_docker.sh" ]; then
    cd docker
    chmod +x restore_docker.sh
    ./restore_docker.sh
    cd ..
else
    echo "⚠️ 未找到Docker恢复脚本"
fi

# 恢复网站数据
echo "恢复网站数据..."
if [ -d "websites" ]; then
    for website_file in websites/*.tar.gz; do
        if [ -f "$website_file" ]; then
            site_name=$(basename "$website_file" .tar.gz)
            echo "恢复网站: $site_name"
            # 实际恢复需要根据具体目录结构调整
            echo "⚠️ 需要手动恢复网站: $website_file"
        fi
    done
else
    echo "⚠️ 未找到网站数据备份"
fi

# 恢复数据库
echo "恢复数据库..."
if [ -d "databases" ]; then
    echo "📋 检测到的数据库备份:"
    find databases -name "*.sql.gz" -o -name "*.tar.gz" -o -name "*.rdb" 2>/dev/null | while read db_file; do
        echo "  - $db_file"
    done
    echo "⚠️ 数据库恢复需要手动操作，请参考 databases/ 目录下的备份文件"
else
    echo "⚠️ 未找到数据库备份"
fi

# 恢复SSL证书
echo "恢复SSL证书..."
if [ -d "ssl" ]; then
    if [ -f "ssl/letsencrypt.tar.gz" ]; then
        echo "恢复Let's Encrypt证书..."
        tar -xzf ssl/letsencrypt.tar.gz -C /etc/
    fi
    if [ -f "ssl/ssl_certs.tar.gz" ]; then
        echo "恢复SSL证书..."
        tar -xzf ssl/ssl_certs.tar.gz -C /etc/
    fi
    echo "✅ SSL证书恢复完成"
else
    echo "⚠️ 未找到SSL证书备份"
fi

# 恢复网盘配置
echo "检查网盘配置..."
if [ -f "backup_info.txt" ]; then
    echo "备份信息文件包含网盘配置信息"
    grep -i "网盘\|cloud\|onedrive\|google\|baidu" backup_info.txt || true
    echo "⚠️ 网盘配置恢复需要手动操作，请参考备份信息文件"
fi

echo ""
echo "=========================================================="
echo "                   恢复完成                               "
echo "=========================================================="
echo "📋 后续检查事项:"
echo "1. 检查系统服务是否正常: systemctl status nginx/apache2/mysql等"
echo "2. 检查Docker容器是否正常运行: docker ps"
echo "3. 检查网站是否可访问"
echo "4. 检查数据库连接"
echo "5. 检查SSL证书是否有效"
echo "6. 检查网盘配置是否正常（如果配置了）"
echo ""
echo "💡 重要提示:"
echo "- 某些恢复操作可能需要重启服务"
echo "- 用户密码恢复需要额外处理"
echo "- 检查防火墙和网络配置"
echo "- 验证备份数据的完整性"
echo "=========================================================="
EOF

chmod +x $BACKUP_DIR/hostrecover.sh

# 创建恢复说明文档
{
    echo "=========================================================="
    echo "          RojoHome 系统备份恢复说明文档                   "
    echo "=========================================================="
    echo "备份时间: $(date)"
    echo "备份文件: $BACKUP_FILE"
    echo "系统版本: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2)"
    echo "内核版本: $(uname -r)"
    echo "主机名: $(hostname)"
    echo "设备名称: $HOSTNAME"
    echo "远程目录: $REMOTE_BACKUP_DIR"
    echo "网盘目录: $BYPY_CLOUD_DIR"
    echo "Docker镜像备份模式: $DOCKER_IMAGE_BACKUP_MODE"
    echo "备份方式: $BACKUP_METHOD"
    echo "网盘类型: $BACKUP_CLOUD_TYPES"
    if [[ "$BACKUP_CLOUD_TYPES" == *"onedrive"* ]]; then
        echo "OneDrive远程名称: $ONEDRIVE_REMOTE_NAME"
        echo "OneDrive文件夹: $ONEDRIVE_REMOTE_FOLDER"
        echo "Drive ID: $ONEDRIVE_DRIVE_ID"
        echo "Drive Type: $ONEDRIVE_DRIVE_TYPE"
    fi
    if [[ "$BACKUP_CLOUD_TYPES" == *"google"* ]]; then
        echo "Google Drive远程名称: $GDRIVE_REMOTE_NAME"
    fi
    echo "备份保留天数: $RETENTION_DAYS 天"
    echo "每日备份时间: $BACKUP_HOUR:$BACKUP_MINUTE"
    echo "=========================================================="
    echo ""
    echo "📁 备份内容概述:"
    echo "1. 系统信息"
    echo "2. Docker环境 (容器、网络、卷、镜像等)"
    echo "3. 网站数据"
    echo "4. 数据库备份"
    echo "5. SSL证书"
    echo "6. 系统配置文件"
    echo "7. 用户数据"
    echo "8. 网盘配置信息"
    echo ""
    echo "🚀 快速恢复指南:"
    echo "1. 将备份文件复制到目标服务器"
    echo "2. 解压备份文件: tar -xzf $(basename $BACKUP_FILE)"
    echo "3. 运行恢复脚本: ./hostrecover.sh"
    echo "4. 按照提示完成恢复"
    echo ""
    echo "📋 详细恢复步骤:"
    echo ""
    echo "一、系统环境准备"
    echo "   - 确保目标系统与备份系统版本相近"
    echo "   - 以root用户执行恢复操作"
    echo "   - 确保有足够的磁盘空间"
    echo ""
    echo "二、Docker环境恢复"
    echo "   - 如果备份了Docker镜像，会自动加载"
    echo "   - 根据容器配置信息重新创建容器"
    echo "   - 检查网络和卷配置"
    echo ""
    echo "三、数据库恢复"
    echo "   - MySQL: 使用 mysql -u root -p < backup.sql"
    echo "   - PostgreSQL: 使用 psql -U postgres -f backup.sql"
    echo "   - MongoDB: 使用 mongorestore --dir backup_dir"
    echo "   - Redis: 复制 RDB 文件到数据目录"
    echo ""
    echo "四、网站数据恢复"
    echo "   - 解压网站数据到对应目录"
    echo "   - 设置正确的权限"
    echo "   - 重启Web服务器"
    echo ""
    echo "五、SSL证书恢复"
    echo "   - 复制证书文件到 /etc/ssl/ 或 /etc/letsencrypt/"
    echo "   - 更新Web服务器配置"
    echo "   - 重启Web服务器"
    echo ""
    echo "六、网盘配置恢复"
    if [[ "$BACKUP_CLOUD_TYPES" == *"onedrive"* ]]; then
        echo "   - OneDrive配置: 远程名称: $ONEDRIVE_REMOTE_NAME"
        echo "   - OneDrive文件夹: $ONEDRIVE_REMOTE_FOLDER"
    fi
    if [[ "$BACKUP_CLOUD_TYPES" == *"google"* ]]; then
        echo "   - Google Drive配置: 远程名称: $GDRIVE_REMOTE_NAME"
    fi
    if [[ "$BACKUP_CLOUD_TYPES" == *"baidu"* ]]; then
        echo "   - 百度网盘配置: 目录: $BYPY_CLOUD_DIR"
    fi
    echo ""
    echo "⚠️ 注意事项:"
    echo "   - 恢复前请备份现有数据"
    echo "   - 某些操作可能需要手动干预"
    echo "   - 检查服务依赖关系"
    echo "   - 验证恢复后的系统功能"
    echo ""
    echo "🔧 故障排除:"
    echo "   - 查看恢复脚本的输出信息"
    echo "   - 检查系统日志: journalctl -xe"
    echo "   - 验证服务状态: systemctl status service_name"
    echo "   - 检查文件权限和所有权"
    echo ""
    echo "📞 支持信息:"
    echo "   如有问题，请参考以下文件:"
    echo "   - backup_info.txt (备份详细信息)"
    echo "   - backup_manifest.txt (文件清单)"
    echo "   - 各目录下的恢复说明"
    echo "=========================================================="
} > $BACKUP_DIR/恢复说明.txt

{
    echo "=========================================================="
    echo "          RojoHome 系统备份信息           "
    echo "=========================================================="
    echo "备份时间: $(date)"
    echo "备份文件: $BACKUP_FILE"
    echo "系统版本: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2)"
    echo "内核版本: $(uname -r)"
    echo "主机名: $(hostname)"
    echo "设备名称: $HOSTNAME"
    echo "远程目录: $REMOTE_BACKUP_DIR"
    echo "网盘目录: $BYPY_CLOUD_DIR"
    echo "Docker镜像备份模式: $DOCKER_IMAGE_BACKUP_MODE"
    echo "备份方式: $BACKUP_METHOD"
    echo "网盘类型: $BACKUP_CLOUD_TYPES"
    if [[ "$BACKUP_CLOUD_TYPES" == *"onedrive"* ]]; then
        echo "OneDrive远程名称: $ONEDRIVE_REMOTE_NAME"
        echo "OneDrive文件夹: $ONEDRIVE_REMOTE_FOLDER"
        echo "Drive ID: $ONEDRIVE_DRIVE_ID"
        echo "Drive Type: $ONEDRIVE_DRIVE_TYPE"
    fi
    if [[ "$BACKUP_CLOUD_TYPES" == *"google"* ]]; then
        echo "Google Drive远程名称: $GDRIVE_REMOTE_NAME"
    fi
    echo "通知方式: $NOTIFICATION_METHOD"
    echo "备份保留天数: $RETENTION_DAYS 天"
    echo "每日备份时间: $BACKUP_HOUR:$BACKUP_MINUTE"
    echo "本地备份路径: $BACKUP_BASE"
    echo "=========================================================="
    echo ""
    echo "恢复指南:"
    echo "1. 解压备份文件: tar -xzf $BACKUP_NAME.tar.gz"
    echo "2. 查看备份内容: cat backup_manifest.txt"
    echo "3. 运行自动恢复: ./hostrecover.sh"
    echo "4. 恢复Docker: 执行 docker/restore_docker.sh"
    echo "5. 恢复数据库: 参考 databases/ 目录下的备份文件"
    echo "6. 恢复网站数据: 参考 websites/ 目录"
    echo "7. 恢复配置文件: 参考 etc/ 和 configs/ 目录"
    echo "8. 恢复网盘配置: 参考 backup_info.txt 中的网盘信息"
    echo ""
    echo "重要提示:"
    echo "- 恢复脚本: hostrecover.sh"
    echo "- 恢复说明: 恢复说明.txt"
    echo "- Docker恢复: docker/restore_docker.sh"
    echo "- 恢复前请确保系统环境与备份时一致"
    echo "=========================================================="
} > $BACKUP_DIR/backup_info.txt

log "✅ 备份清单和恢复指南创建完成"

# 14. 创建压缩包
log "14. 创建压缩包..."
cd /tmp
tar -czf $BACKUP_FILE $BACKUP_NAME/ 2>/dev/null

if [ $? -eq 0 ] && [ -f "$BACKUP_FILE" ]; then
    BACKUP_SIZE=$(du -h $BACKUP_FILE | cut -f1)
    log "✅ 压缩包创建成功: $BACKUP_FILE ($BACKUP_SIZE)"
    LOCAL_BACKUP_STATUS="success"
else
    log "❌ 压缩包创建失败"
    LOCAL_BACKUP_STATUS="failed"
    exit 1
fi

# 15. 清理临时文件
rm -rf $BACKUP_DIR
log "✅ 临时文件清理完成"

# 16. 清理本地旧备份
find $BACKUP_BASE -name "debian_backup_*.tar.gz" -mtime +$RETENTION_DAYS -delete 2>/dev/null && log "  ✅ 本地旧备份清理完成"

# 17. 根据备份方式进行备份
log "17. 执行备份策略: $BACKUP_METHOD"

# 执行各种备份方式
case "$BACKUP_METHOD" in
    "local")
        log "✅ 仅本地备份完成"
        ;;
    "remote")
        if command -v rclone &> /dev/null; then
            if check_existing_rclone_config; then
                backup_to_all_remotes
            else
                log "❌ 未找到有效的Rclone配置，无法进行远程备份"
            fi
        else
            log "❌ Rclone未安装，无法进行远程备份"
        fi
        ;;
    "cloud")
        log "☁️  开始网盘备份..."
        backup_to_cloud_storage
        ;;
    "both_remote")
        log "✅ 本地备份完成"
        if command -v rclone &> /dev/null; then
            if check_existing_rclone_config; then
                backup_to_all_remotes
            else
                log "❌ 未找到有效的Rclone配置，无法进行远程备份"
            fi
        else
            log "❌ Rclone未安装，无法进行远程备份"
        fi
        ;;
    "both_cloud")
        log "✅ 本地备份完成"
        log "☁️  开始网盘备份..."
        backup_to_cloud_storage
        ;;
    "all")
        log "✅ 本地备份完成"
        if command -v rclone &> /dev/null; then
            if check_existing_rclone_config; then
                backup_to_all_remotes
            else
                log "❌ 未找到有效的Rclone配置，无法进行远程备份"
            fi
        else
            log "❌ Rclone未安装，无法进行远程备份"
        fi
        log "☁️  开始网盘备份..."
        backup_to_cloud_storage
        ;;
    *)
        log "⚠️ 未知备份方式: $BACKUP_METHOD，仅执行本地备份"
        ;;
esac

# 计算总执行时间
END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))

# 显示执行时间
show_execution_time

# 发送备份完成通知
log "18. 发送备份完成通知..."
send_backup_notification "$BACKUP_FILE" "$BACKUP_SIZE" "$TOTAL_TIME"

log "🎉 RojoHome备份任务全部完成!"
log "📦 最终备份文件: $BACKUP_FILE"
log "💾 文件大小: $BACKUP_SIZE"
log "🏠 设备名称: $HOSTNAME"
log "📁 远程目录: $REMOTE_BACKUP_DIR"
log "☁️  网盘目录: $BYPY_CLOUD_DIR"
log "🔧 备份方式: $BACKUP_METHOD"
if [ -n "$BACKUP_CLOUD_TYPES" ]; then
    log "📱 网盘类型: $BACKUP_CLOUD_TYPES"
fi
log "🐳 Docker镜像备份: $DOCKER_IMAGE_BACKUP_MODE"
log "🔔 通知方式: $NOTIFICATION_METHOD"
log "📅 备份保留天数: $RETENTION_DAYS 天"
log "⏰ 每日备份时间: $BACKUP_HOUR:$BACKUP_MINUTE"
log "⏱️ 总执行时间: ${TOTAL_TIME}秒"

# 显示备份状态总结
echo ""
echo "=========================================================="
echo "                   备份状态总结                           "
echo "=========================================================="
echo "📊 本地备份: $LOCAL_BACKUP_STATUS"

if [ ${#REMOTE_BACKUP_STATUS[@]} -gt 0 ]; then
    echo "📡 远程备份状态:"
    for remote_name in "${!REMOTE_BACKUP_STATUS[@]}"; do
        echo "  - $remote_name: ${REMOTE_BACKUP_STATUS[$remote_name]}"
    done
fi

if [ -n "$BACKUP_CLOUD_TYPES" ]; then
    IFS=',' read -ra cloud_types <<< "$BACKUP_CLOUD_TYPES"
    if [ ${#cloud_types[@]} -gt 0 ]; then
        echo "☁️  网盘备份状态:"
        for cloud_type in "${cloud_types[@]}"; do
            cloud_status="${CLOUD_BACKUP_STATUS[$cloud_type]}"
            if [ -z "$cloud_status" ]; then
                cloud_status="未执行"
            fi
            echo "  - $cloud_type: $cloud_status"
        done
    fi
fi
echo "=========================================================="

echo ""
echo "=========================================================="
echo "                   恢复信息                               "
echo "=========================================================="
echo "📋 恢复脚本和说明文档已包含在备份包中:"
echo "   - 自动恢复脚本: hostrecover.sh"
echo "   - 详细恢复说明: 恢复说明.txt" 
echo "   - Docker恢复脚本: docker/restore_docker.sh"
echo "   - 备份信息文件: backup_info.txt"
echo ""
echo "🚀 快速恢复命令:"
echo "   tar -xzf $(basename $BACKUP_FILE) && ./hostrecover.sh"
echo ""
echo "💡 提示: 恢复前请仔细阅读恢复说明文档"
echo "=========================================================="