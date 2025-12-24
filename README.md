# Oracle Cloud 免费 ARM 实例自动抢购工具

自动抢购 Oracle Cloud 免费 ARM 实例（最高可配置 4 OCPU / 24GB RAM），支持循环重试、429 限流退避、邮件通知，成功后自动停止。

## ✨ 功能特点

- 🔄 **自动循环抢购** - 每 5 分钟尝试所有可用域
- 🛡️ **429 限流保护** - 遇到 API 限流自动指数退避（5s → 60s）
- 📧 **邮件通知** - 成功创建实例后发送邮件，包含 SSH 连接命令
- 🔌 **开机自启** - 未成功前保持运行，成功后自动禁用
- 📝 **详细日志** - 完整记录所有操作
- 🌐 **使用现有网络** - 不创建新的 VCN，使用现有子网

## 📋 前置条件

- 一台已有的服务器（用于运行脚本）
- Oracle Cloud 账户（已开通免费层）
- SMTP 邮箱（用于接收通知）

## 🚀 快速开始

### 步骤 1: 获取 Oracle Cloud 配置

#### 1.1 获取 Tenancy OCID（租户 ID）

1. 登录 [Oracle Cloud Console](https://cloud.oracle.com)
2. 点击右上角头像 → **Tenancy: xxx**
3. 复制 **OCID**

```
格式示例: ocid1.tenancy.oc1..aaaaaaaxxxxxxxxxxxxxxxxxx
```

#### 1.2 获取 Compartment OCID（隔间 ID）

通常与 Tenancy OCID 相同（使用 root compartment），或者：
1. 进入 **Identity & Security** → **Compartments**
2. 选择目标隔间，复制 **OCID**

#### 1.3 获取 Subnet OCID（子网 ID）

1. 进入 **Networking** → **Virtual Cloud Networks**
2. 选择一个 VCN → 点击子网
3. 复制子网的 **OCID**

> 💡 如果没有 VCN，请先创建：VCN 向导会自动创建子网、互联网网关等

#### 1.4 获取 User OCID（用户 ID）

1. 点击右上角头像 → **My Profile**
2. 复制 **OCID**

```
格式示例: ocid1.user.oc1..aaaaaaaxxxxxxxxxxxxxxxxxx
```

#### 1.5 生成 API 密钥

1. 在 **My Profile** 页面，左侧点击 **API keys**
2. 点击 **Add API key**
3. 选择 **Generate API key pair**
4. **下载私钥**（.pem 文件）- 妥善保管！
5. 点击 **Add**
6. 复制显示的 **fingerprint**

```
指纹格式示例: 89:4f:de:06:79:9a:ae:18:6e:4c:10:69:c3:bb:55:1a
```

---

### 步骤 2: 生成 SSH 密钥

在本地电脑上生成 SSH 密钥对（用于登录新创建的实例）：

```bash
# 生成密钥对（无密码）
ssh-keygen -t ed25519 -C "your_email@example.com" -f ~/.ssh/oracle_arm -N ""

# 查看公钥（需要填入脚本）
cat ~/.ssh/oracle_arm.pub
```

输出示例：
```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIxxxxxxx your_email@example.com
```

---

### 步骤 3: 获取 SMTP 邮箱配置

#### QQ 邮箱（推荐）

| 配置项 | 值 |
|--------|-----|
| SMTP 服务器 | `smtp.qq.com` |
| 端口 | `587` |

**获取授权码：**
1. 登录 [mail.qq.com](https://mail.qq.com)
2. 设置 → 账户 → POP3/IMAP/SMTP 服务
3. 开启 SMTP 服务
4. 获取 16 位授权码

#### Gmail

| 配置项 | 值 |
|--------|-----|
| SMTP 服务器 | `smtp.gmail.com` |
| 端口 | `587` |

需要开启两步验证并生成应用专用密码。

---

### 步骤 4: 配置脚本

1. 复制模板文件：
```bash
cp oracle_arm_grabber_template.sh oracle_arm_grabber.sh
```

2. 编辑脚本，填入您的配置：
```bash
vim oracle_arm_grabber.sh
```

需要修改的配置项：

```bash
# ====== Oracle Cloud 配置 ======
TENANCY_OCID="<your_tenancy_ocid>"
COMPARTMENT_OCID="<your_compartment_ocid>"
SSH_PUB_KEY="<your_ssh_public_key>"

# ====== 使用现有的 VCN 和子网 ======
SUBNET_OCID="<your_subnet_ocid>"

# ====== 实例配置 ======
OCPUS=2          # CPU 核心数 (1-4)
MEM_GB=16        # 内存 GB (6-24)

# ====== 邮件通知配置 ======
SMTP_SERVER="smtp.qq.com"
SMTP_PORT="587"
SMTP_USER="<your_email>"
SMTP_PASSWORD="<your_smtp_password>"
NOTIFY_EMAIL="<notification_email>"
```

---

### 步骤 5: 部署到服务器

#### 5.1 上传文件

```bash
scp oracle_arm_grabber.sh oracle-arm-grabber.service user@your-server:/tmp/
```

#### 5.2 登录服务器安装 OCI CLI

```bash
ssh user@your-server

# 安装 OCI CLI
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" -- --accept-all-defaults

# 添加到 PATH
echo 'export PATH=$HOME/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
```

#### 5.3 配置 OCI CLI 认证

```bash
mkdir -p ~/.oci

# 上传 API 私钥
# (从本地上传 .pem 文件到服务器 ~/.oci/oci_api_key.pem)

# 创建配置文件
cat > ~/.oci/config << EOF
[DEFAULT]
user=<your_user_ocid>
fingerprint=<your_api_key_fingerprint>
tenancy=<your_tenancy_ocid>
region=us-ashburn-1
key_file=~/.oci/oci_api_key.pem
EOF

chmod 600 ~/.oci/config ~/.oci/oci_api_key.pem
```

#### 5.4 验证 OCI CLI

```bash
oci iam region list --query "data[].name" --output table
```

如果显示区域列表，说明配置成功。

#### 5.5 安装服务

```bash
# 复制脚本
sudo mkdir -p /opt/oracle-arm-grabber
sudo cp /tmp/oracle_arm_grabber.sh /opt/oracle-arm-grabber/
sudo chmod +x /opt/oracle-arm-grabber/oracle_arm_grabber.sh

# 复制 OCI 配置给 root
sudo mkdir -p /root/.oci
sudo cp ~/.oci/config /root/.oci/
sudo cp ~/.oci/oci_api_key.pem /root/.oci/
sudo sed -i "s|~/.oci|/root/.oci|g" /root/.oci/config
sudo chmod 600 /root/.oci/config /root/.oci/oci_api_key.pem

# 安装 systemd 服务
sudo cp /tmp/oracle-arm-grabber.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable oracle-arm-grabber
sudo systemctl start oracle-arm-grabber
```

---

## 📊 使用指南

### 查看服务状态

```bash
sudo systemctl status oracle-arm-grabber
```

### 查看实时日志

```bash
sudo tail -f /var/log/oracle_arm_grabber.log
```

### 停止服务

```bash
sudo systemctl stop oracle-arm-grabber
```

### 重启服务

```bash
sudo systemctl restart oracle-arm-grabber
```

### 手动运行（测试）

```bash
sudo /opt/oracle-arm-grabber/oracle_arm_grabber.sh
```

---

## 📧 通知示例

成功创建实例后，您会收到类似这样的邮件：

```
主题: 🎉 Oracle ARM 实例创建成功!

恭喜！您的免费 ARM 实例已成功创建！

===== 实例信息 =====
名称: free-arm-ubuntu
配置: 2 OCPU / 16GB RAM
实例ID: ocid1.instance.oc1.iad.xxx
公网IP: 123.45.67.89

===== SSH 登录方式 =====
ssh -i ~/.ssh/oracle_arm ubuntu@123.45.67.89
```

---

## ⚙️ 配置说明

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `OCPUS` | 2 | CPU 核心数（免费额度最多 4） |
| `MEM_GB` | 16 | 内存大小 GB（免费额度最多 24） |
| `RETRY_INTERVAL` | 300 | 正常重试间隔（秒） |
| `BACKOFF_INITIAL` | 5 | 限流退避初始时间（秒） |
| `BACKOFF_MAX` | 60 | 限流退避最大时间（秒） |

### Oracle 免费额度说明

- **总额度**: 4 OCPU + 24GB RAM
- **可拆分**: 可以创建多个小实例，如 2x(2C8G)
- **Shape**: VM.Standard.A1.Flex

---

## 🔧 故障排除

### OCI CLI 未找到

```
ERROR: OCI CLI not found
```
**解决**: 确保 PATH 包含 OCI CLI 路径：
```bash
export PATH=$HOME/bin:$PATH
```

### API 认证失败

```
NotAuthenticated
```
**解决**: 
1. 检查 `~/.oci/config` 配置
2. 确认 API 密钥已上传到 Oracle Cloud Console
3. 检查 fingerprint 是否匹配

### 429 限流

```
TooManyRequests
```
**解决**: 脚本会自动退避，无需干预。如频繁出现，可增加 `RETRY_INTERVAL`。

### 容量不足

```
Out of host capacity
```
**正常**: 这表示当前没有可用资源，脚本会继续重试。

---

## 📁 文件说明

| 文件 | 说明 |
|------|------|
| `oracle_arm_grabber.sh` | 您的个人配置版本 |
| `oracle_arm_grabber_template.sh` | 通用模板（无私人信息） |
| `oracle-arm-grabber.service` | systemd 服务文件 |
| `README.md` | 本文档 |

---

## 📜 License

MIT License

---

## 🙏 致谢

感谢 Oracle Cloud 提供的免费 Always Free 资源。
