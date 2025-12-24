#!/usr/bin/env bash
# ============================================================
# Oracle Cloud 免费 ARM 实例自动抢购脚本 - 通用模板
# 
# 使用前请填写下方所有 <xxx> 占位符
# 详细配置说明请参考 README.md
# ============================================================

export PATH=/home/ubuntu/bin:$PATH
set -euo pipefail

# ============================================================
# 配置区域 - 请修改以下所有配置项
# ============================================================

# ====== Oracle Cloud 配置 ======
# 获取方式: OCI Console -> 右上角头像 -> Tenancy
TENANCY_OCID="<your_tenancy_ocid>"

# 获取方式: 通常与 TENANCY_OCID 相同，或在 Identity -> Compartments 中查看
COMPARTMENT_OCID="<your_compartment_ocid>"

# 获取方式: 在本地运行 ssh-keygen 生成，然后 cat ~/.ssh/oracle_arm.pub
SSH_PUB_KEY="<your_ssh_public_key>"

# ====== 使用现有的 VCN 和子网 ======
# 获取方式: Networking -> Virtual Cloud Networks -> 选择 VCN -> 子网 -> 复制 OCID
SUBNET_OCID="<your_subnet_ocid>"

# ====== 实例配置 ======
DISPLAY_NAME="free-arm-ubuntu"   # 实例名称
SHAPE="VM.Standard.A1.Flex"      # ARM 实例类型（不要修改）
OCPUS=2                          # CPU 核心数 (1-4，免费额度共 4 核)
MEM_GB=16                        # 内存 GB (6-24，免费额度共 24GB)

# ====== 邮件通知配置 ======
# QQ 邮箱: smtp.qq.com:587，需要开启 SMTP 并获取授权码
# Gmail: smtp.gmail.com:587，需要开启两步验证并生成应用专用密码
SMTP_SERVER="smtp.qq.com"
SMTP_PORT="587"
SMTP_USER="<your_email@qq.com>"
SMTP_PASSWORD="<your_16_digit_auth_code>"
NOTIFY_EMAIL="<notification_email@example.com>"

# ====== 重试配置 ======
RETRY_INTERVAL=300      # 正常重试间隔（秒）= 5分钟
MAX_RETRIES=0           # 0 = 无限重试
BACKOFF_INITIAL=5       # 限流退避初始时间（秒）
BACKOFF_MAX=60          # 限流退避最大时间（秒）

# ====== 日志配置 ======
LOG_FILE="/var/log/oracle_arm_grabber.log"
SUCCESS_FLAG="/opt/oracle-arm-grabber/.success"

# ============================================================
# 以下代码无需修改
# ============================================================

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >&2
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

send_email() {
    local subject="$1"
    local body="$2"
    
    log "Sending email notification..."
    
    python3 << EOF
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart

try:
    msg = MIMEMultipart()
    msg['From'] = "${SMTP_USER}"
    msg['To'] = "${NOTIFY_EMAIL}"
    msg['Subject'] = "${subject}"
    
    body = """${body}"""
    msg.attach(MIMEText(body, 'plain', 'utf-8'))
    
    server = smtplib.SMTP("${SMTP_SERVER}", ${SMTP_PORT})
    server.starttls()
    server.login("${SMTP_USER}", "${SMTP_PASSWORD}")
    server.sendmail("${SMTP_USER}", "${NOTIFY_EMAIL}", msg.as_string())
    server.quit()
    print("Email sent successfully!")
except Exception as e:
    print(f"Failed to send email: {e}")
EOF
}

handle_rate_limit() {
    local backoff=$BACKOFF_INITIAL
    log "Rate limit detected (429). Starting exponential backoff..."
    
    while [[ $backoff -le $BACKOFF_MAX ]]; do
        log "Waiting ${backoff}s before retry..."
        sleep $backoff
        backoff=$((backoff * 2))
        if [[ $backoff -gt $BACKOFF_MAX ]]; then
            backoff=$BACKOFF_MAX
        fi
    done
    
    log "Backoff complete. Resuming normal operation."
}

disable_autostart() {
    log "Disabling autostart for oracle-arm-grabber service..."
    touch "$SUCCESS_FLAG"
    systemctl disable oracle-arm-grabber 2>/dev/null || true
    log "Autostart disabled. Service will not start on next boot."
}

grab_arm_instance() {
    log "Fetching availability domains..."
    local ad_output=$(oci iam availability-domain list \
        --compartment-id "$TENANCY_OCID" \
        --query "data[].name" --raw-output 2>&1)
    
    if echo "$ad_output" | grep -qiE "429|TooManyRequests|rate limit"; then
        handle_rate_limit
        return 1
    fi
    
    mapfile -t ADS < <(echo "$ad_output" | tr -d '[]"' | tr ',' '\n' | sed 's/^ *//' | grep -v '^$')
    
    if [[ ${#ADS[@]} -eq 0 ]]; then
        log "ERROR: No availability domains found"
        return 1
    fi
    
    log "Fetching latest Ubuntu ARM image..."
    IMAGE_ID=$(oci compute image list \
        --compartment-id "$TENANCY_OCID" \
        --operating-system "Canonical Ubuntu" \
        --operating-system-version "22.04" \
        --shape "$SHAPE" \
        --sort-by TIMECREATED --sort-order DESC \
        --query "data[0].id" --raw-output 2>&1)
    
    if echo "$IMAGE_ID" | grep -qiE "429|TooManyRequests|rate limit"; then
        handle_rate_limit
        return 1
    fi
    
    log "Using image: $IMAGE_ID"
    log "Using subnet: $SUBNET_OCID"
    log "Available ADs: ${ADS[*]}"
    
    META_FILE=$(mktemp)
    cat > "$META_FILE" << EOF
{"ssh_authorized_keys":"$SSH_PUB_KEY"}
EOF
    
    local retry_count=0
    
    while true; do
        for AD in "${ADS[@]}"; do
            [[ -z "$AD" ]] && continue
            
            log "==> Trying AD: $AD (Attempt: $((retry_count + 1)))"
            
            set +e
            OUT=$(oci compute instance launch \
                --availability-domain "$AD" \
                --compartment-id "$COMPARTMENT_OCID" \
                --display-name "$DISPLAY_NAME" \
                --shape "$SHAPE" \
                --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEM_GB}" \
                --subnet-id "$SUBNET_OCID" \
                --assign-public-ip true \
                --image-id "$IMAGE_ID" \
                --metadata "file://$META_FILE" \
                2>&1)
            RC=$?
            set -e
            
            if echo "$OUT" | grep -qiE "429|TooManyRequests|rate limit"; then
                log "Rate limit hit during instance launch. Backing off..."
                handle_rate_limit
                continue
            fi
            
            if [[ $RC -eq 0 ]]; then
                log "🎉 SUCCESS! Instance created!"
                log "$OUT"
                
                INSTANCE_ID=$(echo "$OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])" 2>/dev/null || echo "unknown")
                
                log "Waiting for instance to get public IP..."
                sleep 60
                
                PUBLIC_IP=$(oci compute instance list-vnics \
                    --instance-id "$INSTANCE_ID" \
                    --query "data[0].\"public-ip\"" --raw-output 2>/dev/null || echo "pending")
                
                send_email "🎉 Oracle ARM 实例创建成功!" "
恭喜！您的免费 ARM 实例已成功创建！

===== 实例信息 =====
名称: $DISPLAY_NAME
配置: ${OCPUS} OCPU / ${MEM_GB}GB RAM
实例ID: $INSTANCE_ID
公网IP: $PUBLIC_IP
可用域: $AD
创建时间: $(date '+%Y-%m-%d %H:%M:%S')

===== SSH 登录方式 =====
ssh -i ~/.ssh/oracle_arm ubuntu@$PUBLIC_IP

请登录 Oracle Cloud 控制台查看详情：
https://cloud.oracle.com/compute/instances
"
                rm -f "$META_FILE"
                disable_autostart
                log "Script completed successfully. Exiting."
                exit 0
            fi
            
            if echo "$OUT" | grep -qiE "Out of host capacity|Out of capacity|InternalError|LimitExceeded"; then
                log "No capacity in $AD, trying next..."
                continue
            fi
            
            log "Error in $AD: $(echo "$OUT" | head -c 300)"
        done
        
        retry_count=$((retry_count + 1))
        
        if [[ $MAX_RETRIES -gt 0 && $retry_count -ge $MAX_RETRIES ]]; then
            log "Max retries ($MAX_RETRIES) reached. Exiting."
            rm -f "$META_FILE"
            return 1
        fi
        
        log "All ADs tried. Sleeping ${RETRY_INTERVAL}s ($(($RETRY_INTERVAL/60)) min) before retry..."
        sleep "$RETRY_INTERVAL"
    done
}

main() {
    if [[ -f "$SUCCESS_FLAG" ]]; then
        log "Instance already created previously. Exiting."
        log "To run again, delete: $SUCCESS_FLAG"
        exit 0
    fi
    
    log "============================================"
    log "Oracle ARM Instance Grabber Started"
    log "============================================"
    log "Target: $DISPLAY_NAME ($OCPUS OCPU, ${MEM_GB}GB RAM)"
    log "Subnet: $SUBNET_OCID"
    log "Retry interval: ${RETRY_INTERVAL}s ($(($RETRY_INTERVAL/60)) min)"
    log "Backoff: ${BACKOFF_INITIAL}s - ${BACKOFF_MAX}s"
    
    if ! command -v oci &> /dev/null; then
        log "ERROR: OCI CLI not found. Please install it first."
        exit 1
    fi
    
    log "Starting instance grab loop..."
    grab_arm_instance
}

main "$@"
