#!/bin/bash
# =====================================================
#  Hysteria2 中转 → SOCKS5 住宅节点 万能部署脚本 (泰国部署版)
#  By Wayne Shen
#
#  架构说明：
#    - Hysteria2 是 UDP/QUIC 协议，单进程只能监听一个端口
#    - 多节点 = 多 systemd 实例 (hysteria-server@nodeN.service)
#    - 每个实例有独立配置文件 /etc/hysteria/node-N.yaml
#    - 每个实例对应一个落地 SOCKS5（或 VPS 直连）
#    - 自签证书 + 客户端 insecure=1 (泰国无 GFW，无需伪装)
# =====================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ===== 路径常量 =====
HY_DIR="/etc/hysteria"                       # 配置根目录
HY_CERT_DIR="${HY_DIR}/certs"                # 自签证书目录
META_FILE="${HY_DIR}/.nodes_meta.json"       # 节点元信息（端口/落地/密码/备注）
INFO_FILE="/root/hysteria_nodes_info.txt"
SYSCTL_FILE="/etc/sysctl.d/99-hysteria.conf"
IP_CACHE_FILE="/root/.hysteria_vps_ip"

# 客户端 SNI（自签时随便给一个域名即可，客户端 insecure=1）
SNI_HOST="${SNI_HOST:-bing.com}"

# ========== 工具函数 ==========
print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════╗"
    echo "║   Hysteria2 中转部署工具 v1.0 (泰国版)       ║"
    echo "║   多节点 · 一键部署 · 自动优化               ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

get_ip() {
    if [ -f "$IP_CACHE_FILE" ]; then
        local cache_age=$(( $(date +%s) - $(stat -c %Y "$IP_CACHE_FILE" 2>/dev/null || echo 0) ))
        if [ "$cache_age" -lt 86400 ]; then
            local cached_ip=$(cat "$IP_CACHE_FILE" 2>/dev/null)
            if [ -n "$cached_ip" ]; then
                echo "$cached_ip"
                return
            fi
        fi
    fi

    IP=$(curl -s4 --max-time 5 ip.sb 2>/dev/null || \
         curl -s4 --max-time 5 ifconfig.me 2>/dev/null || \
         curl -s4 --max-time 5 icanhazip.com 2>/dev/null || true)
    if [ -z "$IP" ]; then
        echo -e "${RED}无法获取本机公网 IP，请手动输入:${NC}" >&2
        read -p "VPS 公网 IP: " IP
    fi

    echo "$IP" > "$IP_CACHE_FILE" 2>/dev/null
    echo "$IP"
}

# 确保 qrencode 已安装（用于生成 hysteria2 链接的终端二维码）
ensure_qrencode() {
    if command -v qrencode &>/dev/null; then
        return 0
    fi
    echo -e "${YELLOW}首次使用二维码功能，正在安装 qrencode...${NC}" >&2
    local rc=1
    if command -v apt-get &>/dev/null; then
        apt-get install -y qrencode >/dev/null 2>&1 && rc=0 || rc=1
    elif command -v dnf &>/dev/null; then
        dnf install -y qrencode >/dev/null 2>&1 && rc=0 || rc=1
    elif command -v yum &>/dev/null; then
        yum install -y qrencode >/dev/null 2>&1 && rc=0 || rc=1
    else
        echo -e "${RED}未检测到支持的包管理器 (apt/dnf/yum)，跳过二维码显示${NC}" >&2
        return 1
    fi
    if [ "$rc" -eq 0 ]; then
        return 0
    else
        echo -e "${RED}qrencode 安装失败，将跳过二维码显示（链接仍可手动复制）${NC}" >&2
        return 1
    fi
}

# 在终端输出 hysteria2 链接的二维码
# 用法: show_qrcode "<hysteria2链接>" "<节点名(可选)>"
show_qrcode() {
    local link="$1"
    local name="${2:-节点}"

    [ -z "$link" ] && return 0
    ensure_qrencode || return 0

    echo ""
    echo -e "${GREEN}┌─ 扫码导入 [${name}] ──────────────────────────${NC}"
    echo -e "${CYAN}  Shadowrocket / NekoBox / Hiddify / V2rayNG 均可扫码${NC}"
    echo ""
    qrencode -t ANSIUTF8 -m 2 "$link" || {
        echo -e "${RED}  二维码生成失败${NC}"
        return 0
    }
    echo -e "${GREEN}└──────────────────────────────────────────────${NC}"
    echo ""
}

# 安全地下载并执行官方 Hysteria2 安装脚本
# 用法: run_hysteria_installer install | remove
run_hysteria_installer() {
    local action="${1:-install}"
    echo "正在从 GitHub 下载 Hysteria2 安装脚本..."
    local install_script
    install_script=$(curl -fsSL --max-time 15 \
        https://get.hy2.sh/ 2>/dev/null || true)
    if [ -z "$install_script" ]; then
        echo -e "${RED}✗ 无法连接到 GitHub 下载 Hysteria2 安装脚本${NC}"
        echo -e "${YELLOW}  建议：检查网络、配置 DNS (1.1.1.1 / 8.8.8.8)${NC}"
        return 1
    fi
    if [ "$action" = "remove" ]; then
        bash -c "$install_script" -- --remove
    else
        bash -c "$install_script"
    fi
}

# 生成自签证书（一次生成全节点共用，反正客户端 insecure=1）
ensure_self_signed_cert() {
    mkdir -p "$HY_CERT_DIR"
    local cert="${HY_CERT_DIR}/cert.pem"
    local key="${HY_CERT_DIR}/key.pem"
    if [ -f "$cert" ] && [ -f "$key" ]; then
        return 0
    fi
    if ! command -v openssl &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            apt-get install -y openssl >/dev/null 2>&1
        elif command -v dnf &>/dev/null; then
            dnf install -y openssl >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y openssl >/dev/null 2>&1
        fi
    fi
    openssl ecparam -genkey -name prime256v1 -out "$key" 2>/dev/null
    openssl req -new -x509 -days 36500 -key "$key" -out "$cert" \
        -subj "/CN=${SNI_HOST}" 2>/dev/null
    # Hysteria 以 hysteria 用户运行，要给读权限
    chown -R hysteria:hysteria "$HY_CERT_DIR" 2>/dev/null || true
    chmod 644 "$cert"
    chmod 640 "$key"
}

# 元数据存储：保存所有节点信息到 META_FILE，方便后续增删改查
# 格式: { "nodes": [ {idx, port, password, s_host, s_port, s_user, s_pass, name, traffic_port}, ... ] }
init_meta_if_missing() {
    if [ ! -f "$META_FILE" ]; then
        mkdir -p "$HY_DIR"
        echo '{"nodes":[]}' > "$META_FILE"
    fi
}

get_next_inbound_port() {
    META_FILE="$META_FILE" python3 << 'PYEOF'
import json, os, sys

with open(os.environ["META_FILE"], "r") as f:
    meta = json.load(f)

used = {n["port"] for n in meta.get("nodes", [])}

candidate = 8443
while candidate in used:
    candidate += 1
    if candidate > 20000:
        print("ERROR: next inbound port exceeds 20000")
        sys.exit(0)

print(candidate)
PYEOF
}

# 找下一个可用的本地 traffic stats HTTP 端口（监听 127.0.0.1 即可）
get_next_traffic_port() {
    META_FILE="$META_FILE" python3 << 'PYEOF'
import json, os
with open(os.environ["META_FILE"], "r") as f:
    meta = json.load(f)
used = {n.get("traffic_port", 0) for n in meta.get("nodes", [])}
candidate = 27000
while candidate in used:
    candidate += 1
print(candidate)
PYEOF
}

get_next_idx() {
    META_FILE="$META_FILE" python3 << 'PYEOF'
import json, os
with open(os.environ["META_FILE"], "r") as f:
    meta = json.load(f)
nodes = meta.get("nodes", [])
if not nodes:
    print(1)
else:
    print(max(n["idx"] for n in nodes) + 1)
PYEOF
}

port_in_use_udp() {
    local port="$1"
    ss -uln 2>/dev/null | grep -q ":${port} "
}

port_in_use_tcp() {
    local port="$1"
    ss -tln 2>/dev/null | grep -q ":${port} "
}

# Hysteria2 是 UDP，所以放行 UDP 端口
apply_firewall_port() {
    local port="$1"

    # 优先级 1: UFW
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${port}/udp" >/dev/null 2>&1 || true
        return
    fi

    # 优先级 2: firewalld
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        firewall-cmd --zone=public --add-port="${port}/udp" --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        return
    fi

    # 优先级 3: 裸 iptables
    iptables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true

    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 || true
    elif [ -d /etc/iptables ]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
}

# ========== 更新操作系统 ==========
update_system() {
    echo -e "${GREEN}[步骤0] 更新操作系统...${NC}"

    if command -v apt &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt update -y
        apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
        apt install -y curl python3 iproute2 ca-certificates openssl
        apt autoremove -y
        echo -e "  ${GREEN}✓ 系统已更新 (apt)${NC}"
    elif command -v dnf &>/dev/null; then
        dnf update -y
        dnf install -y curl python3 iproute ca-certificates openssl
        echo -e "  ${GREEN}✓ 系统已更新 (dnf)${NC}"
    elif command -v yum &>/dev/null; then
        yum update -y
        yum install -y curl python3 iproute ca-certificates openssl
        echo -e "  ${GREEN}✓ 系统已更新 (yum)${NC}"
    else
        echo -e "  ${YELLOW}⚠ 未识别的包管理器，跳过系统更新${NC}"
    fi

    if ! command -v python3 &>/dev/null; then
        echo -e "  ${RED}✗ 未检测到 python3，脚本无法继续${NC}"
        exit 1
    fi
}

# ========== 安装 Hysteria2 ==========
install_hysteria() {
    echo -e "${GREEN}[步骤1] 检查并安装 Hysteria2...${NC}"
    if command -v hysteria &> /dev/null; then
        echo "Hysteria2 已安装: $(hysteria version 2>/dev/null | head -1)"
    else
        echo "正在安装 Hysteria2..."
        if ! run_hysteria_installer install; then
            echo -e "${RED}Hysteria2 安装失败，无法继续部署${NC}"
            exit 1
        fi
    fi
    # 官方安装脚本会创建 /etc/hysteria 与 hysteria 用户，并提供 hysteria-server@.service 模板
    mkdir -p "$HY_DIR" "$HY_CERT_DIR" /var/log/hysteria
    chown -R hysteria:hysteria /var/log/hysteria 2>/dev/null || true
}

collect_nodes() {
    echo ""
    echo -e "${GREEN}[步骤3] 添加 SOCKS5 住宅节点${NC}"
    echo -e "${CYAN}格式: IP:端口:用户名:密码${NC}"
    echo -e "${CYAN}例如: 161.77.77.5:12324:14a0f0ecfa3d6:384cafa39d${NC}"
    echo -e "${CYAN}（如果暂无住宅节点，可直接输入 done 跳过，脚本会创建一个 443 端口的 VPS 直连节点作为起点）${NC}"
    echo ""

    local SEP=$'\x1f'
    NODES=()
    NODE_NUM=0

    while true; do
        NODE_NUM=$((NODE_NUM + 1))
        read -p "节点${NODE_NUM} (输入 done 结束): " INPUT

        if [ "$INPUT" = "done" ] || [ "$INPUT" = "d" ] || [ -z "$INPUT" ]; then
            if [ ${#NODES[@]} -eq 0 ]; then
                echo ""
                echo -e "${YELLOW}你还没有添加任何住宅 SOCKS5 节点。${NC}"
                echo -e "${YELLOW}是否创建一个 443 端口的 VPS 直连节点作为起点？${NC}"
                echo -e "${CYAN}（流量将直接从 VPS 机房 IP 出口，不经过住宅 IP；之后可随时通过菜单选项 2 追加住宅节点）${NC}"
                read -p "输入 y 创建直连起步节点 / 其他任意键继续录入住宅节点: " EMPTY_CHOICE
                if [ "$EMPTY_CHOICE" = "y" ] || [ "$EMPTY_CHOICE" = "Y" ]; then
                    NODES+=("443${SEP}__DIRECT__${SEP}${SEP}${SEP}${SEP}VPS-Direct")
                    echo -e "${GREEN}  ✓ 已添加直连起步节点: VPS-Direct (监听端口: 443/UDP)${NC}"
                    break
                fi
                NODE_NUM=0
                continue
            fi
            break
        fi

        IFS=':' read -r S_HOST S_PORT S_USER S_PASS <<< "$INPUT"

        if [ -z "$S_HOST" ] || [ -z "$S_PORT" ] || [ -z "$S_USER" ] || [ -z "$S_PASS" ]; then
            echo -e "${RED}格式错误，请使用 IP:端口:用户名:密码${NC}"
            NODE_NUM=$((NODE_NUM - 1))
            continue
        fi

        # 第一个节点用 443/UDP，第二个起从 8443 段递增
        if [ $NODE_NUM -eq 1 ]; then
            LISTEN_PORT=443
        else
            LISTEN_PORT=$((8442 + NODE_NUM))
        fi

        read -p "  备注名称 (如 KR-Seoul / US-LA，回车跳过): " NODE_NAME
        [ -z "$NODE_NAME" ] && NODE_NAME="Node-${NODE_NUM}"
        NODE_NAME=$(echo "$NODE_NAME" | tr ' \t#?&\r\n' '-' | tr -s '-' | sed 's/^-//; s/-$//')
        [ -z "$NODE_NAME" ] && NODE_NAME="Node-${NODE_NUM}"

        NODES+=("${LISTEN_PORT}${SEP}${S_HOST}${SEP}${S_PORT}${SEP}${S_USER}${SEP}${S_PASS}${SEP}${NODE_NAME}")
        echo -e "${GREEN}  ✓ 已添加: ${NODE_NAME} → ${S_HOST}:${S_PORT} (监听端口: ${LISTEN_PORT}/UDP)${NC}"
        echo ""
    done
}

# 给单个节点写入配置 + 启动 systemd 实例
# 用法: write_node_config <idx> <port> <password> <s_host> <s_port> <s_user> <s_pass> <name> <traffic_port>
write_node_config() {
    local idx="$1" port="$2" password="$3"
    local s_host="$4" s_port="$5" s_user="$6" s_pass="$7"
    local name="$8" traffic_port="$9"

    local cfg="${HY_DIR}/node-${idx}.yaml"

    # 用 Python 生成完整 YAML，避免密码/账号里包含 YAML 特殊字符（: { } @ # 等）导致解析失败
    HY_CERT_DIR="$HY_CERT_DIR" SNI_HOST="$SNI_HOST" \
    IDX="$idx" PORT="$port" PASSWORD="$password" \
    S_HOST="$s_host" S_PORT="$s_port" S_USER="$s_user" S_PASS="$s_pass" \
    NAME="$name" TRAFFIC_PORT="$traffic_port" \
    CFG="$cfg" \
    python3 << 'PYEOF'
import os, json
# 不依赖 PyYAML（系统可能没装），手动生成 YAML，对所有可能含特殊字符的字段统一用 JSON 字符串
# (YAML 是 JSON 的超集，所以 JSON 风格的双引号字符串永远是合法 YAML)

idx = os.environ["IDX"]
port = os.environ["PORT"]
password = os.environ["PASSWORD"]
s_host = os.environ["S_HOST"]
s_port = os.environ["S_PORT"]
s_user = os.environ["S_USER"]
s_pass = os.environ["S_PASS"]
name = os.environ["NAME"]
traffic_port = os.environ["TRAFFIC_PORT"]
cert_dir = os.environ["HY_CERT_DIR"]
sni = os.environ["SNI_HOST"]
cfg_path = os.environ["CFG"]

def q(s):
    """用 JSON 编码确保字符串在 YAML 里安全：处理 : @ # & * 等特殊字符"""
    return json.dumps(s, ensure_ascii=False)

is_direct = (s_host == "__DIRECT__")

lines = []
lines.append(f"# Hysteria2 节点 #{idx} - {name}" + (" (VPS 直连)" if is_direct else f" → {s_host}:{s_port}"))
lines.append(f"listen: :{port}")
lines.append("")
lines.append("tls:")
lines.append(f"  cert: {cert_dir}/cert.pem")
lines.append(f"  key: {cert_dir}/key.pem")
lines.append("")
lines.append("auth:")
lines.append("  type: password")
lines.append(f"  password: {q(password)}")
lines.append("")
lines.append("trafficStats:")
lines.append(f"  listen: 127.0.0.1:{traffic_port}")
lines.append("")
lines.append("# 中转场景：不强制 bandwidth，让 BBR 拥塞控制自适应")
lines.append("ignoreClientBandwidth: false")
lines.append("disableUDP: false")
lines.append("")

if not is_direct:
    lines.append("outbounds:")
    lines.append("  - name: residential")
    lines.append("    type: socks5")
    lines.append("    socks5:")
    lines.append(f"      addr: {q(f'{s_host}:{s_port}')}")
    lines.append(f"      username: {q(s_user)}")
    lines.append(f"      password: {q(s_pass)}")
    lines.append("")
    lines.append("# 默认全部走 residential 出站")
    lines.append("acl:")
    lines.append("  inline:")
    lines.append("    - residential(all)")
    lines.append("")

lines.append("masquerade:")
lines.append("  type: proxy")
lines.append("  proxy:")
lines.append(f"    url: https://www.{sni}/")
lines.append("    rewriteHost: true")

with open(cfg_path, "w") as f:
    f.write("\n".join(lines) + "\n")
PYEOF

    chown hysteria:hysteria "$cfg" 2>/dev/null || true
    chmod 640 "$cfg"
}

# 启动单个节点的 systemd 实例
# 官方安装脚本提供 hysteria-server@.service 模板，配置文件读 /etc/hysteria/<instance>.yaml
start_node_instance() {
    local idx="$1"
    systemctl daemon-reload
    systemctl enable "hysteria-server@node-${idx}.service" >/dev/null 2>&1
    systemctl restart "hysteria-server@node-${idx}.service"
}

stop_node_instance() {
    local idx="$1"
    systemctl stop "hysteria-server@node-${idx}.service" 2>/dev/null || true
    systemctl disable "hysteria-server@node-${idx}.service" 2>/dev/null || true
}

# 把 NODES[] 数组里的节点全部写入元数据 + 配置文件 + 启动
generate_config() {
    echo -e "${GREEN}[步骤4] 生成 Hysteria2 配置文件...${NC}"
    init_meta_if_missing
    ensure_self_signed_cert

    local SEP=$'\x1f'
    for NODE in "${NODES[@]}"; do
        IFS="$SEP" read -r PORT S_HOST S_PORT S_USER S_PASS NAME <<< "$NODE"

        local idx
        idx=$(get_next_idx)
        local password
        password=$(python3 -c 'import os; print(os.urandom(12).hex())')
        local traffic_port
        traffic_port=$(get_next_traffic_port)

        # 写元数据
        META_FILE="$META_FILE" \
        IDX="$idx" PORT="$PORT" PASSWORD="$password" \
        S_HOST="$S_HOST" S_PORT="$S_PORT" S_USER="$S_USER" S_PASS="$S_PASS" \
        NAME="$NAME" TRAFFIC_PORT="$traffic_port" \
        python3 << 'PYEOF'
import json, os
with open(os.environ["META_FILE"], "r") as f:
    meta = json.load(f)
meta["nodes"].append({
    "idx": int(os.environ["IDX"]),
    "port": int(os.environ["PORT"]),
    "password": os.environ["PASSWORD"],
    "s_host": os.environ["S_HOST"],
    "s_port": os.environ["S_PORT"],
    "s_user": os.environ["S_USER"],
    "s_pass": os.environ["S_PASS"],
    "name": os.environ["NAME"],
    "traffic_port": int(os.environ["TRAFFIC_PORT"])
})
with open(os.environ["META_FILE"], "w") as f:
    json.dump(meta, f, indent=2, ensure_ascii=False)
PYEOF

        write_node_config "$idx" "$PORT" "$password" "$S_HOST" "$S_PORT" "$S_USER" "$S_PASS" "$NAME" "$traffic_port"
    done

    echo -e "  ✓ 配置已写入 ${HY_DIR}/node-*.yaml"
    echo -e "  ✓ 元数据已写入 ${META_FILE}"
    echo -e "  ✓ 流量统计 API 已启用 (本地 27000+ 端口)"
}

optimize_system() {
    echo -e "${GREEN}[步骤5] 系统优化 (BBR + UDP 缓冲区调优)...${NC}"

    if [ -f "$SYSCTL_FILE" ]; then
        echo "  sysctl 优化配置已存在，跳过写入"
    else
        cat > "$SYSCTL_FILE" << 'EOF'
# === Hysteria2 中转优化 ===
# Hysteria2 是 UDP/QUIC 协议，UDP 缓冲区是大头
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=2500000
net.core.wmem_default=2500000
net.core.netdev_max_backlog=8192
net.core.somaxconn=8192
# TCP 调优（虽然 Hysteria2 是 UDP，但 SOCKS5 上行仍是 TCP）
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
EOF
        sysctl --system >/dev/null 2>&1 || true
        echo "  ✓ BBR 和内核参数配置已写入 ${SYSCTL_FILE}"
    fi

    # Hysteria2 使用 systemd 模板服务，给所有实例统一加 LimitNOFILE
    if ! grep -q "LimitNOFILE=65535" /etc/systemd/system/hysteria-server@.service.d/limits.conf 2>/dev/null; then
        mkdir -p /etc/systemd/system/hysteria-server@.service.d
        cat > /etc/systemd/system/hysteria-server@.service.d/limits.conf << 'EOF'
[Service]
LimitNOFILE=65535
EOF
        systemctl daemon-reload
        echo "  ✓ 文件描述符限制已提升"
    fi

    CURRENT_SWAP=$(free | awk '/Swap:/ {print $2}')
    if [ "${CURRENT_SWAP:-0}" -eq 0 ] && [ ! -f /swapfile ]; then
        if fallocate -l 1G /swapfile 2>/dev/null && \
           chmod 600 /swapfile && \
           mkswap /swapfile >/dev/null 2>&1 && \
           swapon /swapfile 2>/dev/null; then
            grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
            echo "  ✓ 1G Swap 已添加"
        else
            echo -e "  ${YELLOW}⚠ Swap 创建失败，跳过${NC}"
            rm -f /swapfile
        fi
    else
        echo "  系统已有 Swap，跳过"
    fi
}

setup_firewall() {
    echo -e "${GREEN}[步骤6] 配置防火墙...${NC}"
    META_FILE="$META_FILE" python3 -c "
import json, os
with open(os.environ['META_FILE']) as f:
    meta = json.load(f)
for n in meta['nodes']:
    print(n['port'])
" | while read -r PORT; do
        apply_firewall_port "$PORT"
        echo "  ✓ UDP 端口 ${PORT} 已放行"
    done
}

start_all_services() {
    echo -e "${GREEN}[步骤7] 启动所有 Hysteria2 实例...${NC}"
    systemctl daemon-reload

    META_FILE="$META_FILE" python3 -c "
import json, os
with open(os.environ['META_FILE']) as f:
    meta = json.load(f)
for n in meta['nodes']:
    print(n['idx'])
" | while read -r idx; do
        start_node_instance "$idx"
    done

    sleep 2

    META_FILE="$META_FILE" python3 -c "
import json, os
with open(os.environ['META_FILE']) as f:
    meta = json.load(f)
for n in meta['nodes']:
    print(f\"{n['idx']}|{n['name']}\")
" | while IFS='|' read -r idx name; do
        if systemctl is-active --quiet "hysteria-server@node-${idx}.service"; then
            echo -e "  ${GREEN}✓ 节点 #${idx} (${name}) 启动成功${NC}"
        else
            echo -e "  ${RED}✗ 节点 #${idx} (${name}) 启动失败: journalctl -u hysteria-server@node-${idx} -n 20${NC}"
        fi
    done
}

# 生成 hysteria2:// 链接
# hysteria2://<password>@<host>:<port>/?sni=<sni>&insecure=1#<name>
build_link() {
    local password="$1" host="$2" port="$3" name="$4"
    # name 需要 URL 编码（备注里如果有 # 会断链）— 我们已经在 collect_nodes 里清理过特殊字符
    echo "hysteria2://${password}@${host}:${port}/?sni=${SNI_HOST}&insecure=1#${name}"
}

print_result() {
    VPS_IP=$(get_ip)

    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              部署完成！                       ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    > "$INFO_FILE"

    META_FILE="$META_FILE" python3 -c "
import json, os
with open(os.environ['META_FILE']) as f:
    meta = json.load(f)
for n in meta['nodes']:
    print(f\"{n['idx']}|{n['port']}|{n['password']}|{n['s_host']}|{n['s_port']}|{n['name']}\")
" | while IFS='|' read -r idx port password s_host s_port name; do
        local LINK
        LINK=$(build_link "$password" "$VPS_IP" "$port" "$name")

        echo -e "${GREEN}━━━ ${name} ━━━${NC}"
        echo -e "  监听端口: ${port}/UDP"
        if [ "$s_host" = "__DIRECT__" ]; then
            echo -e "  出口:     VPS 直连 (${VPS_IP})"
        else
            echo -e "  落地节点: ${s_host}:${s_port}"
        fi
        echo -e "  密码:     ${password}"
        echo -e "${YELLOW}  ${LINK}${NC}"
        echo ""

        echo "=== ${name} ===" >> "$INFO_FILE"
        echo "端口: ${port}/UDP" >> "$INFO_FILE"
        if [ "$s_host" = "__DIRECT__" ]; then
            echo "出口: VPS 直连 (${VPS_IP})" >> "$INFO_FILE"
        else
            echo "落地: ${s_host}:${s_port}" >> "$INFO_FILE"
        fi
        echo "密码: ${password}" >> "$INFO_FILE"
        echo "链接: ${LINK}" >> "$INFO_FILE"
        echo "" >> "$INFO_FILE"

        show_qrcode "$LINK" "$name"
    done

    echo -e "${GREEN}━━━ 通用信息 ━━━${NC}"
    echo -e "  VPS IP:    ${VPS_IP}"
    echo -e "  SNI:       ${SNI_HOST} (自签证书，客户端 insecure=1)"
    echo ""
    echo -e "${GREEN}所有链接已保存到 ${INFO_FILE}${NC}"
}

add_node() {
    echo -e "${GREEN}[添加节点模式]${NC}"

    VPS_IP=$(get_ip)
    init_meta_if_missing

    if [ ! -f "$META_FILE" ] || ! command -v hysteria &>/dev/null; then
        echo -e "${RED}未找到现有部署，请先完整安装！${NC}"
        exit 1
    fi

    ensure_self_signed_cert

    NEW_PORT=$(get_next_inbound_port)
    if [[ "$NEW_PORT" == ERROR:* ]]; then
        echo -e "${RED}${NEW_PORT}${NC}"
        exit 1
    fi
    while port_in_use_udp "$NEW_PORT"; do
        NEW_PORT=$((NEW_PORT + 1))
        if [ "$NEW_PORT" -gt 20000 ]; then
            echo -e "${RED}未找到可用监听端口，请手动检查端口占用${NC}"
            exit 1
        fi
    done

    echo -e "新的监听端口: ${NEW_PORT}/UDP"
    echo ""
    echo -e "${CYAN}输入新的 SOCKS5 节点 (格式: IP:端口:用户名:密码)${NC}"
    read -p "节点信息: " INPUT

    IFS=':' read -r S_HOST S_PORT S_USER S_PASS <<< "$INPUT"
    if [ -z "$S_HOST" ] || [ -z "$S_PORT" ] || [ -z "$S_USER" ] || [ -z "$S_PASS" ]; then
        echo -e "${RED}格式错误！${NC}"
        exit 1
    fi

    read -p "备注名称: " NODE_NAME
    [ -z "$NODE_NAME" ] && NODE_NAME="Node-new"
    NODE_NAME=$(echo "$NODE_NAME" | tr ' \t#?&\r\n' '-' | tr -s '-' | sed 's/^-//; s/-$//')
    [ -z "$NODE_NAME" ] && NODE_NAME="Node-new"

    local IDX PASSWORD TRAFFIC_PORT
    IDX=$(get_next_idx)
    PASSWORD=$(python3 -c 'import os; print(os.urandom(12).hex())')
    TRAFFIC_PORT=$(get_next_traffic_port)

    # 写元数据
    META_FILE="$META_FILE" \
    IDX="$IDX" PORT="$NEW_PORT" PASSWORD="$PASSWORD" \
    S_HOST="$S_HOST" S_PORT="$S_PORT" S_USER="$S_USER" S_PASS="$S_PASS" \
    NAME="$NODE_NAME" TRAFFIC_PORT="$TRAFFIC_PORT" \
    python3 << 'PYEOF'
import json, os
with open(os.environ["META_FILE"], "r") as f:
    meta = json.load(f)
meta["nodes"].append({
    "idx": int(os.environ["IDX"]),
    "port": int(os.environ["PORT"]),
    "password": os.environ["PASSWORD"],
    "s_host": os.environ["S_HOST"],
    "s_port": os.environ["S_PORT"],
    "s_user": os.environ["S_USER"],
    "s_pass": os.environ["S_PASS"],
    "name": os.environ["NAME"],
    "traffic_port": int(os.environ["TRAFFIC_PORT"])
})
with open(os.environ["META_FILE"], "w") as f:
    json.dump(meta, f, indent=2, ensure_ascii=False)
PYEOF

    write_node_config "$IDX" "$NEW_PORT" "$PASSWORD" "$S_HOST" "$S_PORT" "$S_USER" "$S_PASS" "$NODE_NAME" "$TRAFFIC_PORT"
    apply_firewall_port "$NEW_PORT"
    start_node_instance "$IDX"

    sleep 2
    if systemctl is-active --quiet "hysteria-server@node-${IDX}.service"; then
        local LINK
        LINK=$(build_link "$PASSWORD" "$VPS_IP" "$NEW_PORT" "$NODE_NAME")
        echo ""
        echo -e "${GREEN}✓ 节点添加成功！${NC}"
        echo -e "${GREEN}端口: ${NEW_PORT}/UDP${NC}"
        echo -e "${GREEN}落地: ${S_HOST}:${S_PORT}${NC}"
        echo -e "${GREEN}密码: ${PASSWORD}${NC}"
        echo -e "${YELLOW}${LINK}${NC}"

        echo "" >> "$INFO_FILE"
        echo "=== ${NODE_NAME} ===" >> "$INFO_FILE"
        echo "端口: ${NEW_PORT}/UDP" >> "$INFO_FILE"
        echo "落地: ${S_HOST}:${S_PORT}" >> "$INFO_FILE"
        echo "密码: ${PASSWORD}" >> "$INFO_FILE"
        echo "链接: ${LINK}" >> "$INFO_FILE"

        show_qrcode "$LINK" "$NODE_NAME"
    else
        echo -e "${RED}启动失败: journalctl -u hysteria-server@node-${IDX} -n 20${NC}"
    fi
}

# ========== 添加 VPS 直连节点 ==========
add_direct_node() {
    echo -e "${GREEN}[添加 VPS 直连节点]${NC}"
    echo -e "${CYAN}此模式不经过住宅 SOCKS5，流量直接从 VPS 出口访问目标站点。${NC}"
    echo -e "${CYAN}目标网站看到的将是你 VPS 的机房 IP。${NC}"
    echo ""

    VPS_IP=$(get_ip)
    init_meta_if_missing

    if [ ! -f "$META_FILE" ] || ! command -v hysteria &>/dev/null; then
        echo -e "${RED}未找到现有部署，请先完成【全新安装】(选项 1)！${NC}"
        return
    fi

    ensure_self_signed_cert

    NEW_PORT=$(get_next_inbound_port)
    if [[ "$NEW_PORT" == ERROR:* ]]; then
        echo -e "${RED}${NEW_PORT}${NC}"
        return
    fi
    while port_in_use_udp "$NEW_PORT"; do
        NEW_PORT=$((NEW_PORT + 1))
        if [ "$NEW_PORT" -gt 20000 ]; then
            echo -e "${RED}未找到可用监听端口，请手动检查端口占用${NC}"
            return
        fi
    done

    echo -e "新的监听端口: ${NEW_PORT}/UDP"

    read -p "备注名称 (如 VPS-Direct / TH-Direct，回车默认 VPS-Direct): " NODE_NAME
    [ -z "$NODE_NAME" ] && NODE_NAME="VPS-Direct"
    NODE_NAME=$(echo "$NODE_NAME" | tr ' \t#?&\r\n' '-' | tr -s '-' | sed 's/^-//; s/-$//')
    [ -z "$NODE_NAME" ] && NODE_NAME="VPS-Direct"

    local IDX PASSWORD TRAFFIC_PORT
    IDX=$(get_next_idx)
    PASSWORD=$(python3 -c 'import os; print(os.urandom(12).hex())')
    TRAFFIC_PORT=$(get_next_traffic_port)

    META_FILE="$META_FILE" \
    IDX="$IDX" PORT="$NEW_PORT" PASSWORD="$PASSWORD" \
    NAME="$NODE_NAME" TRAFFIC_PORT="$TRAFFIC_PORT" \
    python3 << 'PYEOF'
import json, os
with open(os.environ["META_FILE"], "r") as f:
    meta = json.load(f)
meta["nodes"].append({
    "idx": int(os.environ["IDX"]),
    "port": int(os.environ["PORT"]),
    "password": os.environ["PASSWORD"],
    "s_host": "__DIRECT__",
    "s_port": "",
    "s_user": "",
    "s_pass": "",
    "name": os.environ["NAME"],
    "traffic_port": int(os.environ["TRAFFIC_PORT"])
})
with open(os.environ["META_FILE"], "w") as f:
    json.dump(meta, f, indent=2, ensure_ascii=False)
PYEOF

    write_node_config "$IDX" "$NEW_PORT" "$PASSWORD" "__DIRECT__" "" "" "" "$NODE_NAME" "$TRAFFIC_PORT"
    apply_firewall_port "$NEW_PORT"
    start_node_instance "$IDX"

    sleep 2
    if systemctl is-active --quiet "hysteria-server@node-${IDX}.service"; then
        local LINK
        LINK=$(build_link "$PASSWORD" "$VPS_IP" "$NEW_PORT" "$NODE_NAME")
        echo ""
        echo -e "${GREEN}✓ VPS 直连节点添加成功！${NC}"
        echo -e "${GREEN}端口: ${NEW_PORT}/UDP${NC}"
        echo -e "${GREEN}出口: VPS 直连 (${VPS_IP})${NC}"
        echo -e "${GREEN}密码: ${PASSWORD}${NC}"
        echo -e "${YELLOW}${LINK}${NC}"

        echo "" >> "$INFO_FILE"
        echo "=== ${NODE_NAME} ===" >> "$INFO_FILE"
        echo "端口: ${NEW_PORT}/UDP" >> "$INFO_FILE"
        echo "出口: VPS 直连 (${VPS_IP})" >> "$INFO_FILE"
        echo "密码: ${PASSWORD}" >> "$INFO_FILE"
        echo "链接: ${LINK}" >> "$INFO_FILE"

        show_qrcode "$LINK" "$NODE_NAME"
    else
        echo -e "${RED}启动失败: journalctl -u hysteria-server@node-${IDX} -n 20${NC}"
    fi
}

show_status() {
    echo -e "${GREEN}━━━ Hysteria2 实例状态 ━━━${NC}"
    if [ ! -f "$META_FILE" ]; then
        echo "尚未部署"
        return
    fi
    META_FILE="$META_FILE" python3 -c "
import json, os
with open(os.environ['META_FILE']) as f:
    meta = json.load(f)
for n in meta['nodes']:
    print(f\"{n['idx']}|{n['port']}|{n['name']}\")
" | while IFS='|' read -r idx port name; do
        if systemctl is-active --quiet "hysteria-server@node-${idx}.service"; then
            echo -e "  ${GREEN}● 节点 #${idx} (${name}) 端口 ${port}/UDP 运行中${NC}"
        else
            echo -e "  ${RED}○ 节点 #${idx} (${name}) 端口 ${port}/UDP 已停止${NC}"
        fi
    done
    echo ""
    echo -e "${GREEN}━━━ BBR 状态 ━━━${NC}"
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null || echo "BBR 尚未配置"
    echo ""
    echo -e "${GREEN}━━━ 节点信息 ━━━${NC}"
    if [ -f "$INFO_FILE" ]; then
        cat "$INFO_FILE"
    else
        echo "暂无节点信息"
    fi
}

# ========== 流量统计 ==========
TRAFFIC_DB="/root/.hysteria_traffic_db"

# Hysteria2 内置 trafficStats HTTP API：
#   GET http://127.0.0.1:<port>/traffic
#   返回 JSON: {"<auth_password>": {"tx": 123, "rx": 456}}
# 我们每个实例独立监听一个 traffic_port，按 idx 聚合即可

setup_traffic_cron() {
    CRON_SCRIPT="/root/.hysteria_traffic_record.sh"

    cat > "$CRON_SCRIPT" << 'CRONEOF'
#!/bin/bash
META_FILE="/etc/hysteria/.nodes_meta.json"
TRAFFIC_DB="/root/.hysteria_traffic_db"

[ ! -f "$META_FILE" ] && exit 0

META_FILE="$META_FILE" \
TRAFFIC_DB="$TRAFFIC_DB" \
python3 << 'PYEOF'
import json, os, time, urllib.request, subprocess

meta_file = os.environ["META_FILE"]
db_file = os.environ["TRAFFIC_DB"]
timestamp = int(time.time())

with open(meta_file, "r") as f:
    meta = json.load(f)

def get_stat(traffic_port):
    """从 Hysteria2 trafficStats API 拉数据。返回 (tx, rx)。"""
    try:
        req = urllib.request.Request(f"http://127.0.0.1:{traffic_port}/traffic")
        with urllib.request.urlopen(req, timeout=3) as resp:
            data = json.loads(resp.read().decode())
        # 数据结构 {"<password>": {"tx": ..., "rx": ...}}
        # 一个实例只会有一个客户端密码（因为我们一个实例一个节点）
        tx = sum(v.get("tx", 0) for v in data.values())
        rx = sum(v.get("rx", 0) for v in data.values())
        return tx, rx
    except Exception:
        return 0, 0

# 读上一次的累计值
last_cum = {}
if os.path.exists(db_file):
    try:
        with open(db_file, "r") as f:
            for line in f:
                parts = line.strip().split("|")
                if len(parts) >= 5:
                    try:
                        idx = parts[1]
                        cum_up = int(parts[3])
                        cum_down = int(parts[4])
                        last_cum[idx] = (cum_up, cum_down)
                    except ValueError:
                        pass
    except Exception:
        pass

new_rows = []
for n in meta.get("nodes", []):
    idx = str(n["idx"])
    port = n["port"]
    traffic_port = n.get("traffic_port", 0)
    if not traffic_port:
        continue
    # 检查实例是否运行中
    try:
        r = subprocess.run(
            ["systemctl", "is-active", f"hysteria-server@node-{idx}.service"],
            capture_output=True, text=True, timeout=3
        )
        if r.stdout.strip() != "active":
            continue
    except Exception:
        continue

    # tx = 服务端发给客户端 = 客户端的下行；rx = 客户端发给服务端 = 客户端的上行
    # 为了和 Xray 脚本里 up/down 对齐，把 rx 当作 up，tx 当作 down
    cur_down, cur_up = get_stat(traffic_port)

    prev_up, prev_down = last_cum.get(idx, (0, 0))

    # 计数器归零检测（实例重启会归零）
    delta_up = cur_up if cur_up < prev_up else cur_up - prev_up
    delta_down = cur_down if cur_down < prev_down else cur_down - prev_down

    new_rows.append(f"{timestamp}|{idx}|{port}|{cur_up}|{cur_down}|{delta_up}|{delta_down}")

with open(db_file, "a") as f:
    for r in new_rows:
        f.write(r + "\n")

# 清理超过 60 天的旧数据
cutoff = timestamp - 60 * 86400
if os.path.exists(db_file):
    with open(db_file, "r") as f:
        lines = f.readlines()
    with open(db_file, "w") as f:
        for line in lines:
            parts = line.strip().split("|")
            if len(parts) >= 5:
                try:
                    if int(parts[0]) > cutoff:
                        f.write(line)
                except ValueError:
                    pass
PYEOF
CRONEOF

    chmod +x "$CRON_SCRIPT"

    if ! crontab -l 2>/dev/null | grep -q "hysteria_traffic_record"; then
        (crontab -l 2>/dev/null || true; echo "*/5 * * * * /root/.hysteria_traffic_record.sh # hysteria_traffic_record") | crontab -
        echo -e "  ${GREEN}✓ 流量记录定时任务已安装 (每5分钟)${NC}"
    fi
}

show_traffic() {
    if [ ! -f "$META_FILE" ]; then
        echo -e "${RED}未找到元数据文件！${NC}"
        return
    fi

    setup_traffic_cron
    bash /root/.hysteria_traffic_record.sh 2>/dev/null

    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              节点流量统计                     ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    META_FILE="$META_FILE" \
    TRAFFIC_DB="$TRAFFIC_DB" \
    python3 << 'PYEOF'
import json, os, time, urllib.request, subprocess

meta_file = os.environ["META_FILE"]
db_file = os.environ["TRAFFIC_DB"]

with open(meta_file, "r") as f:
    meta = json.load(f)

def get_stat(traffic_port):
    try:
        req = urllib.request.Request(f"http://127.0.0.1:{traffic_port}/traffic")
        with urllib.request.urlopen(req, timeout=3) as resp:
            data = json.loads(resp.read().decode())
        tx = sum(v.get("tx", 0) for v in data.values())
        rx = sum(v.get("rx", 0) for v in data.values())
        return tx, rx
    except Exception:
        return 0, 0

def format_bytes(b):
    b = abs(b)
    if b < 1024:
        return f"{b} B"
    elif b < 1024**2:
        return f"{b/1024:.1f} KB"
    elif b < 1024**3:
        return f"{b/1024**2:.1f} MB"
    else:
        return f"{b/1024**3:.2f} GB"

def get_dest(node):
    if node["s_host"] == "__DIRECT__":
        return "VPS"
    return node["s_host"]

# ===== 当前实时流量 =====
print("  ━━━ 当前实时 (自上次启动) ━━━")
print(f"  {'节点':<22} {'上行':>10} {'下行':>10} {'合计':>10}")
print(f"  {'─'*22} {'─'*10} {'─'*10} {'─'*10}")

total_up = 0
total_down = 0

for n in meta.get("nodes", []):
    idx = n["idx"]
    port = n["port"]
    traffic_port = n.get("traffic_port", 0)
    dest = get_dest(n)

    # 检查实例运行状态
    try:
        r = subprocess.run(
            ["systemctl", "is-active", f"hysteria-server@node-{idx}.service"],
            capture_output=True, text=True, timeout=3
        )
        running = r.stdout.strip() == "active"
    except Exception:
        running = False

    if not running:
        name = f":{port}→{dest}"
        print(f"  {name:<22} {'(stopped)':>10} {'':>10} {'':>10}")
        continue

    down, up = get_stat(traffic_port)
    total = up + down
    total_up += up
    total_down += down
    name = f":{port}→{dest}"
    print(f"  {name:<22} {format_bytes(up):>10} {format_bytes(down):>10} {format_bytes(total):>10}")

print(f"  {'─'*22} {'─'*10} {'─'*10} {'─'*10}")
print(f"  {'总计':<22} {format_bytes(total_up):>10} {format_bytes(total_down):>10} {format_bytes(total_up+total_down):>10}")

# ===== 历史流量统计 =====
if not os.path.exists(db_file):
    print("\n  历史数据尚未积累，请等待5分钟后再查看")
else:
    records = []
    with open(db_file, "r") as f:
        for line in f:
            parts = line.strip().split("|")
            if len(parts) >= 7:
                try:
                    ts = int(parts[0])
                    idx = parts[1]
                    port = int(parts[2])
                    delta_up = int(parts[5])
                    delta_down = int(parts[6])
                    records.append((ts, idx, port, delta_up, delta_down))
                except ValueError:
                    pass

    if records:
        now = int(time.time())
        periods = [
            ("过去1小时", now - 3600),
            ("今天", now - (now % 86400)),
            ("过去7天", now - 7 * 86400),
            ("过去30天", now - 30 * 86400),
        ]

        idx_to_node = {str(n["idx"]): n for n in meta["nodes"]}
        idxs_in_records = sorted({r[1] for r in records}, key=lambda x: int(x) if x.isdigit() else 0)

        for period_name, since in periods:
            print(f"\n  ━━━ {period_name} ━━━")
            print(f"  {'节点':<22} {'上行':>10} {'下行':>10} {'合计':>10}")
            print(f"  {'─'*22} {'─'*10} {'─'*10} {'─'*10}")

            p_total_up = 0
            p_total_down = 0

            for idx in idxs_in_records:
                up = sum(r[3] for r in records if r[1] == idx and r[0] >= since)
                down = sum(r[4] for r in records if r[1] == idx and r[0] >= since)
                total = up + down
                p_total_up += up
                p_total_down += down

                node = idx_to_node.get(idx)
                if node:
                    port = node["port"]
                    dest = get_dest(node)
                    name = f":{port}→{dest}"
                else:
                    name = f"#{idx}(已删除)"
                print(f"  {name:<22} {format_bytes(up):>10} {format_bytes(down):>10} {format_bytes(total):>10}")

            print(f"  {'─'*22} {'─'*10} {'─'*10} {'─'*10}")
            print(f"  {'总计':<22} {format_bytes(p_total_up):>10} {format_bytes(p_total_down):>10} {format_bytes(p_total_up+p_total_down):>10}")
PYEOF

    echo ""
    echo -e "${YELLOW}流量每5分钟自动记录一次，历史数据保留60天${NC}"
    echo ""
    echo "  c) 清除历史数据"
    echo "  其他) 返回"
    read -p "  选择: " ACTION
    case $ACTION in
        c)
            rm -f "$TRAFFIC_DB"
            echo -e "${GREEN}✓ 历史数据已清除${NC}"
            ;;
    esac
}

change_port() {
    if [ ! -f "$META_FILE" ]; then
        echo -e "${RED}未找到元数据文件！${NC}"
        return
    fi

    echo -e "${GREEN}[修改端口]${NC}"
    echo "当前节点端口:"
    META_FILE="$META_FILE" python3 << 'PYEOF'
import json, os
with open(os.environ["META_FILE"]) as f:
    meta = json.load(f)
for display_idx, n in enumerate(meta["nodes"], start=1):
    if n["s_host"] == "__DIRECT__":
        dest = " → VPS 直连"
    else:
        dest = f" → {n['s_host']}:{n['s_port']}"
    print(f"  {display_idx}) 端口 {n['port']}/UDP{dest} [#{n['idx']} {n['name']}]")
PYEOF

    echo ""
    read -p "选择要修改的节点编号: " IDX_CHOICE
    read -p "新端口号: " NEW_PORT

    if [ -z "$IDX_CHOICE" ] || [ -z "$NEW_PORT" ]; then
        echo -e "${RED}输入不能为空${NC}"
        return
    fi

    if port_in_use_udp "$NEW_PORT"; then
        echo -e "${RED}UDP 端口 ${NEW_PORT} 已被占用，请换一个端口${NC}"
        return
    fi

    # 更新元数据并取出该节点的真实 idx
    NODE_INFO=$(META_FILE="$META_FILE" IDX_CHOICE="$IDX_CHOICE" NEW_PORT="$NEW_PORT" python3 << 'PYEOF'
import json, os
meta_file = os.environ["META_FILE"]
choice = int(os.environ["IDX_CHOICE"]) - 1
new_port = int(os.environ["NEW_PORT"])

with open(meta_file, "r") as f:
    meta = json.load(f)

if 0 <= choice < len(meta["nodes"]):
    n = meta["nodes"][choice]
    old_port = n["port"]
    n["port"] = new_port
    with open(meta_file, "w") as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)
    # 输出 idx|name|password|s_host|s_port|s_user|s_pass|traffic_port|old_port
    print(f"{n['idx']}|{n['name']}|{n['password']}|{n['s_host']}|{n['s_port']}|{n['s_user']}|{n['s_pass']}|{n['traffic_port']}|{old_port}")
else:
    print("INVALID")
PYEOF
)

    if [ "$NODE_INFO" = "INVALID" ]; then
        echo -e "${RED}编号无效${NC}"
        return
    fi

    IFS='|' read -r N_IDX N_NAME N_PASSWORD N_S_HOST N_S_PORT N_S_USER N_S_PASS N_TRAFFIC_PORT N_OLD_PORT <<< "$NODE_INFO"

    # 重写配置 + 重启实例
    write_node_config "$N_IDX" "$NEW_PORT" "$N_PASSWORD" "$N_S_HOST" "$N_S_PORT" "$N_S_USER" "$N_S_PASS" "$N_NAME" "$N_TRAFFIC_PORT"
    apply_firewall_port "$NEW_PORT"
    systemctl restart "hysteria-server@node-${N_IDX}.service"
    sleep 2

    if systemctl is-active --quiet "hysteria-server@node-${N_IDX}.service"; then
        VPS_IP=$(get_ip)
        local NEW_LINK
        NEW_LINK=$(build_link "$N_PASSWORD" "$VPS_IP" "$NEW_PORT" "$N_NAME")
        echo -e "${GREEN}✓ 端口已从 ${N_OLD_PORT} 修改为 ${NEW_PORT}${NC}"
        echo -e "${YELLOW}新链接:${NC}"
        echo -e "${NEW_LINK}"
        show_qrcode "$NEW_LINK" "$N_NAME"
    else
        echo -e "${RED}重启失败: journalctl -u hysteria-server@node-${N_IDX} -n 20${NC}"
    fi
}

delete_node() {
    if [ ! -f "$META_FILE" ]; then
        echo -e "${RED}未找到元数据文件！${NC}"
        return
    fi

    echo -e "${GREEN}[删除节点]${NC}"
    echo "当前节点:"
    META_FILE="$META_FILE" python3 << 'PYEOF'
import json, os
with open(os.environ["META_FILE"]) as f:
    meta = json.load(f)
for display_idx, n in enumerate(meta["nodes"], start=1):
    if n["s_host"] == "__DIRECT__":
        dest = " → VPS 直连"
    else:
        dest = f" → {n['s_host']}:{n['s_port']}"
    print(f"  {display_idx}) 端口 {n['port']}/UDP{dest} [#{n['idx']} {n['name']}]")
PYEOF

    echo ""
    read -p "选择要删除的节点编号: " IDX_CHOICE

    if [ -z "$IDX_CHOICE" ]; then
        echo -e "${RED}输入不能为空${NC}"
        return
    fi

    DEL_INFO=$(META_FILE="$META_FILE" IDX_CHOICE="$IDX_CHOICE" python3 << 'PYEOF'
import json, os
meta_file = os.environ["META_FILE"]
choice = int(os.environ["IDX_CHOICE"]) - 1

with open(meta_file, "r") as f:
    meta = json.load(f)

if 0 <= choice < len(meta["nodes"]):
    n = meta["nodes"][choice]
    idx = n["idx"]
    port = n["port"]
    name = n["name"]
    meta["nodes"].pop(choice)
    with open(meta_file, "w") as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)
    print(f"{idx}|{port}|{name}")
else:
    print("INVALID")
PYEOF
)

    if [ "$DEL_INFO" = "INVALID" ]; then
        echo -e "${RED}编号无效${NC}"
        return
    fi

    IFS='|' read -r D_IDX D_PORT D_NAME <<< "$DEL_INFO"

    # 停止并删除 systemd 实例 + 配置文件
    stop_node_instance "$D_IDX"
    rm -f "${HY_DIR}/node-${D_IDX}.yaml"

    echo -e "${GREEN}✓ 已删除: 端口 ${D_PORT}/UDP [#${D_IDX} ${D_NAME}]${NC}"
}

troubleshoot() {
    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              排错诊断                         ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    ERRORS=0

    echo -e "${GREEN}[1/8] Hysteria2 实例状态${NC}"
    if [ -f "$META_FILE" ]; then
        local any_node=0
        while IFS='|' read -r idx name; do
            any_node=1
            if systemctl is-active --quiet "hysteria-server@node-${idx}.service"; then
                echo -e "  ${GREEN}✓ 节点 #${idx} (${name}) 正在运行${NC}"
            else
                echo -e "  ${RED}✗ 节点 #${idx} (${name}) 未运行${NC}"
                ERRORS=$((ERRORS + 1))
                echo -e "  ${YELLOW}最近日志:${NC}"
                journalctl -u "hysteria-server@node-${idx}" -n 5 --no-pager 2>/dev/null | sed 's/^/    /'
            fi
        done < <(META_FILE="$META_FILE" python3 -c "
import json, os
with open(os.environ['META_FILE']) as f:
    meta = json.load(f)
for n in meta['nodes']:
    print(f\"{n['idx']}|{n['name']}\")
")
        if [ $any_node -eq 0 ]; then
            echo -e "  ${YELLOW}⚠ 元数据中无节点${NC}"
        fi
    else
        echo -e "  ${RED}✗ 元数据文件不存在${NC}"
        ERRORS=$((ERRORS + 1))
    fi

    echo ""
    echo -e "${GREEN}[2/8] 配置文件检查${NC}"
    if [ -f "$META_FILE" ]; then
        echo -e "  ${GREEN}✓ 元数据文件存在${NC}"
        if python3 -c "import json; json.load(open('$META_FILE'))" 2>/dev/null; then
            echo -e "  ${GREEN}✓ JSON 格式正确${NC}"
        else
            echo -e "  ${RED}✗ JSON 格式错误${NC}"
            ERRORS=$((ERRORS + 1))
        fi
        # 检查每个节点的 yaml 是否存在
        while read -r idx; do
            if [ -f "${HY_DIR}/node-${idx}.yaml" ]; then
                echo -e "  ${GREEN}✓ node-${idx}.yaml 存在${NC}"
            else
                echo -e "  ${RED}✗ node-${idx}.yaml 缺失${NC}"
                ERRORS=$((ERRORS + 1))
            fi
        done < <(META_FILE="$META_FILE" python3 -c "
import json, os
with open(os.environ['META_FILE']) as f:
    meta = json.load(f)
for n in meta['nodes']:
    print(n['idx'])
")
    else
        echo -e "  ${RED}✗ 元数据文件不存在${NC}"
        ERRORS=$((ERRORS + 1))
    fi

    echo ""
    echo -e "${GREEN}[3/8] 证书检查${NC}"
    if [ -f "${HY_CERT_DIR}/cert.pem" ] && [ -f "${HY_CERT_DIR}/key.pem" ]; then
        local exp
        exp=$(openssl x509 -enddate -noout -in "${HY_CERT_DIR}/cert.pem" 2>/dev/null | cut -d= -f2)
        echo -e "  ${GREEN}✓ 自签证书存在 (到期: ${exp})${NC}"
    else
        echo -e "  ${RED}✗ 自签证书缺失${NC}"
        ERRORS=$((ERRORS + 1))
    fi

    echo ""
    echo -e "${GREEN}[4/8] UDP 端口监听检查${NC}"
    if [ -f "$META_FILE" ]; then
        while read -r PORT; do
            if ss -ulnp | grep -q ":${PORT} "; then
                echo -e "  ${GREEN}✓ UDP 端口 ${PORT} 正在监听${NC}"
            else
                echo -e "  ${RED}✗ UDP 端口 ${PORT} 未监听${NC}"
                ERRORS=$((ERRORS + 1))
            fi
        done < <(META_FILE="$META_FILE" python3 -c "
import json, os
with open(os.environ['META_FILE']) as f:
    meta = json.load(f)
for n in meta['nodes']:
    print(n['port'])
")
    fi

    echo ""
    echo -e "${GREEN}[5/8] 防火墙检查${NC}"
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo -e "  UFW: 运行中"
        if [ -f "$META_FILE" ]; then
            while read -r PORT; do
                if ufw status 2>/dev/null | grep "$PORT" | grep -q udp; then
                    echo -e "  ${GREEN}✓ UDP 端口 ${PORT} 已放行 (ufw)${NC}"
                else
                    echo -e "  ${YELLOW}⚠ UDP 端口 ${PORT} 可能未放行 (ufw)${NC}"
                fi
            done < <(META_FILE="$META_FILE" python3 -c "
import json, os
with open(os.environ['META_FILE']) as f:
    meta = json.load(f)
for n in meta['nodes']:
    print(n['port'])
")
        fi
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        echo -e "  firewalld: 运行中"
        if [ -f "$META_FILE" ]; then
            OPEN_PORTS=$(firewall-cmd --list-ports 2>/dev/null || true)
            while read -r PORT; do
                if echo "$OPEN_PORTS" | grep -q "${PORT}/udp"; then
                    echo -e "  ${GREEN}✓ UDP 端口 ${PORT} 已放行 (firewalld)${NC}"
                else
                    echo -e "  ${YELLOW}⚠ UDP 端口 ${PORT} 可能未放行 (firewalld)${NC}"
                fi
            done < <(META_FILE="$META_FILE" python3 -c "
import json, os
with open(os.environ['META_FILE']) as f:
    meta = json.load(f)
for n in meta['nodes']:
    print(n['port'])
")
        fi
    else
        echo -e "  未检测到 UFW 或 firewalld，跳过（使用 iptables 兜底）"
    fi

    echo ""
    echo -e "${GREEN}[6/8] SOCKS5 落地节点连通性${NC}"
    if [ -f "$META_FILE" ]; then
        META_FILE="$META_FILE" python3 << 'PYEOF'
import json, socket, os

with open(os.environ["META_FILE"], "r") as f:
    meta = json.load(f)

for n in meta["nodes"]:
    if n["s_host"] == "__DIRECT__":
        print(f"  - 节点 #{n['idx']} ({n['name']}): VPS 直连，跳过 SOCKS5 检查")
        continue
    addr = n["s_host"]
    port = int(n["s_port"])
    try:
        sock = socket.create_connection((addr, port), timeout=5)
        sock.close()
        print(f"  ✓ {addr}:{port} [#{n['idx']} {n['name']}] 连通")
    except Exception as e:
        print(f"  ✗ {addr}:{port} [#{n['idx']} {n['name']}] 不通 - {e}")
PYEOF
    fi

    echo ""
    echo -e "${GREEN}[7/8] BBR 状态${NC}"
    BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$BBR" = "bbr" ]; then
        echo -e "  ${GREEN}✓ BBR 已启用${NC}"
    else
        echo -e "  ${RED}✗ BBR 未启用 (当前: ${BBR})${NC}"
        ERRORS=$((ERRORS + 1))
    fi

    echo ""
    echo -e "${GREEN}[8/8] 系统资源 + 最近日志${NC}"
    MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
    MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
    if [ "${MEM_TOTAL:-0}" -gt 0 ]; then
        MEM_PERCENT=$((MEM_USED * 100 / MEM_TOTAL))
    else
        MEM_PERCENT=0
    fi
    DISK_PERCENT=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
    CPU_LOAD=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')

    echo -e "  内存: ${MEM_USED}MB / ${MEM_TOTAL}MB (${MEM_PERCENT}%)"
    if [ "$MEM_PERCENT" -gt 90 ]; then
        echo -e "  ${RED}⚠ 内存使用率过高！${NC}"
        ERRORS=$((ERRORS + 1))
    fi
    echo -e "  磁盘: ${DISK_PERCENT}% 已用"
    if [ "$DISK_PERCENT" -gt 90 ]; then
        echo -e "  ${RED}⚠ 磁盘空间不足！${NC}"
        ERRORS=$((ERRORS + 1))
    fi
    echo -e "  负载: ${CPU_LOAD}"

    echo ""
    RECENT_ERRORS=$(journalctl -u 'hysteria-server@*' --since "1 hour ago" --no-pager 2>/dev/null | grep -i -E "error|fail|refused" | tail -5)
    if [ -n "$RECENT_ERRORS" ]; then
        echo -e "  ${YELLOW}最近1小时错误:${NC}"
        echo "$RECENT_ERRORS" | sed 's/^/    /'
    else
        echo -e "  ${GREEN}✓ 最近1小时无错误${NC}"
    fi

    echo ""
    echo -e "${CYAN}━━━ 诊断总结 ━━━${NC}"
    if [ $ERRORS -eq 0 ]; then
        echo -e "${GREEN}✓ 所有检查通过，未发现问题${NC}"
    else
        echo -e "${RED}发现 ${ERRORS} 个问题，请根据上方提示修复${NC}"
    fi
    echo ""
}

uninstall() {
    read -p "确认卸载 Hysteria2？(y/n): " CONFIRM
    if [ "$CONFIRM" = "y" ]; then
        # 停止所有节点实例
        if [ -f "$META_FILE" ]; then
            META_FILE="$META_FILE" python3 -c "
import json, os
with open(os.environ['META_FILE']) as f:
    meta = json.load(f)
for n in meta['nodes']:
    print(n['idx'])
" | while read -r idx; do
                stop_node_instance "$idx"
            done
        fi

        # 停止监控
        systemctl stop hysteria-monitor.timer 2>/dev/null || true
        systemctl disable hysteria-monitor.timer 2>/dev/null || true

        # 卸载主体
        run_hysteria_installer remove || echo -e "${YELLOW}⚠ 官方卸载脚本无法运行，将仅清理本地文件${NC}"

        # 清理 systemd 配置
        rm -f /etc/systemd/system/hysteria-monitor.service
        rm -f /etc/systemd/system/hysteria-monitor.timer
        rm -rf /etc/systemd/system/hysteria-server@.service.d
        systemctl daemon-reload 2>/dev/null || true

        # 清理 cron
        (crontab -l 2>/dev/null || true) | grep -v "hysteria_traffic_record" | crontab - 2>/dev/null || true

        # 清理数据文件
        rm -rf "$HY_DIR"
        rm -f "$INFO_FILE"
        rm -f "$SYSCTL_FILE"
        rm -f /root/.hysteria_traffic_db
        rm -f /root/.hysteria_traffic_record.sh
        rm -f /root/.hysteria_monitor.conf
        rm -f /root/.hysteria_monitor.sh
        rm -f /root/.hysteria_vps_ip
        rm -f /root/.msmtprc
        rm -f /tmp/.hysteria_node_failures
        rm -f /tmp/.hysteria_alert_lock_*

        sysctl --system >/dev/null 2>&1 || true

        if [ -f /swapfile ]; then
            read -p "是否同时移除 /swapfile（1G swap）？(y/n): " RM_SWAP
            if [ "$RM_SWAP" = "y" ]; then
                swapoff /swapfile 2>/dev/null || true
                rm -f /swapfile
                sed -i '\|/swapfile none swap sw 0 0|d' /etc/fstab 2>/dev/null || true
                echo -e "${GREEN}✓ swapfile 已移除${NC}"
            fi
        fi

        echo -e "${GREEN}已完整卸载${NC}"
    fi
}

update_hysteria() {
    echo -e "${GREEN}[更新 Hysteria2]${NC}"

    if command -v hysteria &>/dev/null; then
        CURRENT=$(hysteria version 2>/dev/null | head -1)
        echo -e "  当前版本: ${YELLOW}${CURRENT}${NC}"
    else
        echo -e "  ${RED}Hysteria2 未安装${NC}"
        return
    fi

    echo "  正在检查最新版本..."
    LATEST=$(curl -sL https://api.github.com/repos/apernet/hysteria/releases/latest 2>/dev/null | grep '"tag_name"' | head -1 | cut -d'"' -f4)

    if [ -n "$LATEST" ]; then
        echo -e "  最新版本: ${YELLOW}${LATEST}${NC}"
    else
        echo -e "  ${YELLOW}无法获取最新版本号，将直接更新${NC}"
    fi

    echo ""
    read -p "确认更新？(y/n): " CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        echo "已取消"
        return
    fi

    if ! run_hysteria_installer install; then
        echo -e "${RED}更新中止：无法下载安装脚本，现有 Hysteria2 保持不变${NC}"
        return
    fi

    # 重启所有实例
    if [ -f "$META_FILE" ]; then
        META_FILE="$META_FILE" python3 -c "
import json, os
with open(os.environ['META_FILE']) as f:
    meta = json.load(f)
for n in meta['nodes']:
    print(n['idx'])
" | while read -r idx; do
            systemctl restart "hysteria-server@node-${idx}.service"
        done
    fi
    sleep 2

    NEW_VER=$(hysteria version 2>/dev/null | head -1)
    echo -e "${GREEN}✓ 更新成功: ${NEW_VER}${NC}"
    echo -e "${GREEN}✓ 所有节点实例已重启，配置不变${NC}"
}

# ========== 监控报警 ==========
MONITOR_CONF="/root/.hysteria_monitor.conf"
MONITOR_SCRIPT="/root/.hysteria_monitor.sh"
MONITOR_LOG="/var/log/hysteria/monitor.log"

build_mail() {
    local subject="$1"
    local body="$2"
    local from="$3"
    local to="$4"
    printf "Subject: %s\r\nFrom: %s\r\nTo: %s\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n%s" \
        "$subject" "$from" "$to" "$body"
}

setup_mail() {
    echo -e "${GREEN}[配置邮件通知]${NC}"
    echo ""

    if ! command -v msmtp &>/dev/null; then
        echo "正在安装邮件发送工具..."
        if command -v apt &>/dev/null; then
            apt update -y && apt install -y msmtp msmtp-mta
        elif command -v dnf &>/dev/null; then
            dnf install -y msmtp
        elif command -v yum &>/dev/null; then
            yum install -y msmtp
        else
            echo -e "${RED}未检测到支持的包管理器 (apt/dnf/yum)，请手动安装 msmtp${NC}"
            return 1
        fi
    fi

    echo -e "${CYAN}支持 Gmail / QQ邮箱 / 163邮箱 等${NC}"
    echo ""
    read -p "SMTP 服务器 (如 smtp.gmail.com / smtp.qq.com): " SMTP_HOST
    read -p "SMTP 端口 (通常 587 或 465): " SMTP_PORT
    read -p "发件邮箱: " MAIL_FROM
    read -sp "邮箱密码/授权码: " MAIL_PASS
    echo ""
    read -p "收件邮箱 (报警发到哪): " MAIL_TO

    TLS_TYPE="on"
    TLS_STARTTLS="on"
    if [ "$SMTP_PORT" = "465" ]; then
        TLS_TYPE="on"
        TLS_STARTTLS="off"
    fi

    cat > /root/.msmtprc << EOF
defaults
auth           on
tls            ${TLS_TYPE}
tls_starttls   ${TLS_STARTTLS}
tls_trust_file /etc/ssl/certs/ca-certificates.crt

account        alert
host           ${SMTP_HOST}
port           ${SMTP_PORT}
from           ${MAIL_FROM}
user           ${MAIL_FROM}
password       ${MAIL_PASS}

account default : alert
EOF
    chmod 600 /root/.msmtprc

    cat > "$MONITOR_CONF" << EOF
MAIL_TO=${MAIL_TO}
MAIL_FROM=${MAIL_FROM}
CHECK_INTERVAL=60
AUTO_RESTART=yes
EOF

    echo -e "${YELLOW}正在发送测试邮件...${NC}"
    TEST_BODY="Hysteria2 监控报警测试邮件
服务器: $(curl -s4 --max-time 5 ip.sb 2>/dev/null || echo unknown)
时间: $(date)"

    if build_mail "Hysteria2 Monitor Test" "$TEST_BODY" "$MAIL_FROM" "$MAIL_TO" | msmtp "$MAIL_TO" 2>/dev/null; then
        echo -e "${GREEN}✓ 测试邮件发送成功，请检查收件箱${NC}"
    else
        echo -e "${RED}✗ 发送失败，请检查 SMTP 配置${NC}"
        echo -e "${YELLOW}常见问题：Gmail 需要开启应用专用密码，QQ邮箱需要授权码${NC}"
    fi
}

install_monitor() {
    if [ ! -f "$MONITOR_CONF" ]; then
        echo -e "${RED}请先配置邮件通知（选 a）${NC}"
        return
    fi

    source "$MONITOR_CONF"
    mkdir -p /var/log/hysteria

    cat > "$MONITOR_SCRIPT" << 'MONEOF'
#!/bin/bash
META_FILE="/etc/hysteria/.nodes_meta.json"
MONITOR_CONF="/root/.hysteria_monitor.conf"
MONITOR_LOG="/var/log/hysteria/monitor.log"
ALERT_LOCK="/tmp/.hysteria_alert_lock"

source "$MONITOR_CONF"
VPS_IP=$(curl -s4 ip.sb 2>/dev/null || echo "unknown")
HOSTNAME=$(hostname)
NOW=$(date "+%Y-%m-%d %H:%M:%S")

log() {
    echo "[$NOW] $1" >> "$MONITOR_LOG"
}

send_alert() {
    local SUBJECT="$1"
    local BODY="$2"
    local LOCK_KEY=$(echo "$SUBJECT" | md5sum | cut -d' ' -f1)
    local LOCK_FILE="${ALERT_LOCK}_${LOCK_KEY}"

    if [ -f "$LOCK_FILE" ]; then
        local LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0) ))
        if [ "$LOCK_AGE" -lt 1800 ]; then
            return
        fi
    fi

    local FULL_BODY="${BODY}

服务器: ${VPS_IP} (${HOSTNAME})
时间: ${NOW}"

    printf "Subject: [Hysteria2 Alert] %s\r\nFrom: %s\r\nTo: %s\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n%s" \
        "$SUBJECT" "$MAIL_FROM" "$MAIL_TO" "$FULL_BODY" | msmtp "$MAIL_TO" 2>/dev/null

    touch "$LOCK_FILE"
    log "ALERT SENT: $SUBJECT"
}

ERRORS=0
DETAILS=""

# 检查每个节点实例
if [ -f "$META_FILE" ]; then
    while IFS='|' read -r IDX NAME PORT; do
        if ! systemctl is-active --quiet "hysteria-server@node-${IDX}.service"; then
            ERRORS=$((ERRORS + 1))
            DETAILS="${DETAILS}
[故障] 节点 #${IDX} (${NAME}) 端口 ${PORT}/UDP 已停止"
            log "ERROR: hysteria-server@node-${IDX} not running"

            if [ "$AUTO_RESTART" = "yes" ]; then
                systemctl restart "hysteria-server@node-${IDX}.service"
                sleep 3
                if systemctl is-active --quiet "hysteria-server@node-${IDX}.service"; then
                    DETAILS="${DETAILS}
[恢复] 节点 #${IDX} 已自动重启成功"
                    log "AUTO RESTART: node-${IDX} success"
                else
                    DETAILS="${DETAILS}
[失败] 节点 #${IDX} 自动重启失败，需要手动处理"
                    log "AUTO RESTART: node-${IDX} failed"
                fi
            fi
        fi
    done < <(META_FILE="$META_FILE" python3 -c "
import json, os
with open(os.environ['META_FILE']) as f:
    meta = json.load(f)
for n in meta['nodes']:
    print(f\"{n['idx']}|{n['name']}|{n['port']}\")
")
fi

# 检查 SOCKS5 落地节点连通性
if [ -f "$META_FILE" ]; then
    META_FILE="$META_FILE" python3 << 'PYEOF'
import json, socket, os

with open(os.environ["META_FILE"], "r") as f:
    meta = json.load(f)

failures = []
for n in meta["nodes"]:
    if n["s_host"] == "__DIRECT__":
        continue
    addr = n["s_host"]
    port = int(n["s_port"])
    try:
        sock = socket.create_connection((addr, port), timeout=10)
        sock.close()
    except Exception as e:
        failures.append(f"#{n['idx']} {n['name']} {addr}:{port} - {e}")

failure_file = "/tmp/.hysteria_node_failures"
if failures:
    with open(failure_file, "w") as f:
        for fail in failures:
            f.write(fail + "\n")
else:
    if os.path.exists(failure_file):
        os.remove(failure_file)
PYEOF

    if [ -f /tmp/.hysteria_node_failures ]; then
        ERRORS=$((ERRORS + 1))
        NODE_FAILURES=$(cat /tmp/.hysteria_node_failures)
        DETAILS="${DETAILS}
[故障] 落地节点不通:
${NODE_FAILURES}"
        log "ERROR: Node unreachable: $NODE_FAILURES"
    fi
fi

# 系统资源
MEM_PERCENT=$(free | awk '/Mem:/ {if ($2>0) printf "%.0f", $3/$2*100; else print 0}')
if [ "$MEM_PERCENT" -gt 90 ]; then
    ERRORS=$((ERRORS + 1))
    DETAILS="${DETAILS}
[警告] 内存使用率 ${MEM_PERCENT}%"
    log "WARNING: Memory usage ${MEM_PERCENT}%"
fi

DISK_PERCENT=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
if [ "$DISK_PERCENT" -gt 90 ]; then
    ERRORS=$((ERRORS + 1))
    DETAILS="${DETAILS}
[警告] 磁盘使用率 ${DISK_PERCENT}%"
    log "WARNING: Disk usage ${DISK_PERCENT}%"
fi

# UDP 端口监听
if [ -f "$META_FILE" ]; then
    while read -r PORT; do
        if ! ss -ulnp | grep -q ":${PORT} "; then
            ERRORS=$((ERRORS + 1))
            DETAILS="${DETAILS}
[故障] UDP 端口 ${PORT} 未监听"
            log "ERROR: UDP port ${PORT} not listening"
        fi
    done < <(META_FILE="$META_FILE" python3 -c "
import json, os
with open(os.environ['META_FILE']) as f:
    meta = json.load(f)
for n in meta['nodes']:
    print(n['port'])
")
fi

if [ $ERRORS -gt 0 ]; then
    send_alert "发现 ${ERRORS} 个问题" "$DETAILS"
fi

if [ $ERRORS -eq 0 ]; then
    log "OK: All checks passed"
fi

if [ -f "$MONITOR_LOG" ]; then
    LOG_SIZE=$(stat -c %s "$MONITOR_LOG" 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" -gt 10485760 ]; then
        tail -n 5000 "$MONITOR_LOG" > "${MONITOR_LOG}.tmp"
        mv "${MONITOR_LOG}.tmp" "$MONITOR_LOG"
    fi
fi
MONEOF

    chmod +x "$MONITOR_SCRIPT"

    cat > /etc/systemd/system/hysteria-monitor.service << EOF
[Unit]
Description=Hysteria2 Monitor Check
After=network.target

[Service]
Type=oneshot
ExecStart=/root/.hysteria_monitor.sh
EOF

    cat > /etc/systemd/system/hysteria-monitor.timer << 'EOF'
[Unit]
Description=Hysteria2 Monitor Timer

[Timer]
OnCalendar=minutely
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable hysteria-monitor.timer
    systemctl start hysteria-monitor.timer

    echo -e "${GREEN}✓ 监控已启动（每分钟检查一次）${NC}"
    echo -e "${GREEN}  检查项: 各节点实例 / 落地连通 / 内存 / 磁盘 / UDP 端口${NC}"
    echo -e "${GREEN}  自动重启: 已开启${NC}"
    echo -e "${GREEN}  报警邮件: ${MAIL_TO}${NC}"
    echo -e "${GREEN}  日志文件: ${MONITOR_LOG}${NC}"
}

stop_monitor() {
    systemctl stop hysteria-monitor.timer 2>/dev/null
    systemctl disable hysteria-monitor.timer 2>/dev/null
    echo -e "${GREEN}✓ 监控已停止${NC}"
}

show_monitor_log() {
    if [ -f "$MONITOR_LOG" ]; then
        echo -e "${GREEN}━━━ 最近50条监控日志 ━━━${NC}"
        tail -n 50 "$MONITOR_LOG"
    else
        echo "暂无日志"
    fi
}

monitor_menu() {
    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              监控报警管理                     ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    if systemctl is-active --quiet hysteria-monitor.timer 2>/dev/null; then
        echo -e "  当前状态: ${GREEN}运行中${NC}"
    else
        echo -e "  当前状态: ${RED}未启动${NC}"
    fi
    echo ""

    echo "  a) 配置邮件通知"
    echo "  b) 启动监控"
    echo "  c) 停止监控"
    echo "  d) 查看监控日志"
    echo "  e) 发送测试邮件"
    echo "  f) 返回主菜单"
    echo ""
    read -p "  选择: " MON_CHOICE

    case $MON_CHOICE in
        a)
            setup_mail
            ;;
        b)
            install_monitor
            ;;
        c)
            stop_monitor
            ;;
        d)
            show_monitor_log
            ;;
        e)
            if [ -f "$MONITOR_CONF" ]; then
                source "$MONITOR_CONF"
                VPS_IP=$(get_ip)
                TEST_BODY="测试邮件
服务器: ${VPS_IP}
时间: $(date)"
                if build_mail "Hysteria2 Monitor Test" "$TEST_BODY" "$MAIL_FROM" "$MAIL_TO" | msmtp "$MAIL_TO" 2>/dev/null; then
                    echo -e "${GREEN}✓ 测试邮件已发送${NC}"
                else
                    echo -e "${RED}✗ 发送失败${NC}"
                fi
            else
                echo -e "${RED}请先配置邮件（选 a）${NC}"
            fi
            ;;
        f)
            return
            ;;
    esac
}

# 重启所有实例
restart_all() {
    if [ ! -f "$META_FILE" ]; then
        echo -e "${RED}未找到元数据文件${NC}"
        return
    fi
    META_FILE="$META_FILE" python3 -c "
import json, os
with open(os.environ['META_FILE']) as f:
    meta = json.load(f)
for n in meta['nodes']:
    print(n['idx'])
" | while read -r idx; do
        systemctl restart "hysteria-server@node-${idx}.service"
        echo -e "${GREEN}● 节点 #${idx} 已重启${NC}"
    done
    echo -e "${GREEN}所有节点实例已重启${NC}"
}

# ========== 主菜单 ==========
main_menu() {
    print_banner
    echo "  1) 全新安装 (首次部署)"
    echo "  2) 添加节点"
    echo "  3) 删除节点"
    echo "  4) 修改端口"
    echo "  5) 查看状态"
    echo "  6) 流量统计"
    echo "  7) 排错诊断"
    echo "  8) 更新 Hysteria2"
    echo "  9) 重启所有节点"
    echo "  10) 监控报警"
    echo "  11) 卸载"
    echo "  12) 添加 VPS 直连节点 (不经住宅 IP)"
    echo "  0) 退出"
    echo ""
    read -p "请选择 [0-12]: " CHOICE

    case $CHOICE in
        1)
            update_system
            install_hysteria
            init_meta_if_missing
            collect_nodes
            generate_config
            optimize_system
            setup_firewall
            start_all_services
            print_result
            ;;
        2)
            add_node
            ;;
        3)
            delete_node
            ;;
        4)
            change_port
            ;;
        5)
            show_status
            ;;
        6)
            show_traffic
            ;;
        7)
            troubleshoot
            ;;
        8)
            update_hysteria
            ;;
        9)
            restart_all
            ;;
        10)
            monitor_menu
            ;;
        11)
            uninstall
            ;;
        12)
            add_direct_node
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项${NC}"
            ;;
    esac

    echo ""
    read -p "按回车键返回主菜单..." _
}

# ========== 启动前依赖自检 ==========
preflight_check() {
    local missing=()
    for cmd in python3 curl ss; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}⚠ 缺少必要工具: ${missing[*]}${NC}"
        echo -e "${YELLOW}  正在尝试自动安装...${NC}"
        if command -v apt &>/dev/null; then
            export DEBIAN_FRONTEND=noninteractive
            apt update -y >/dev/null 2>&1 || true
            apt install -y python3 curl iproute2 >/dev/null 2>&1 || true
        elif command -v dnf &>/dev/null; then
            dnf install -y python3 curl iproute >/dev/null 2>&1 || true
        elif command -v yum &>/dev/null; then
            yum install -y python3 curl iproute >/dev/null 2>&1 || true
        fi
        for cmd in python3 curl ss; do
            if ! command -v "$cmd" &>/dev/null; then
                echo -e "${RED}✗ 无法自动安装 $cmd，请手动安装后重试${NC}"
                exit 1
            fi
        done
        echo -e "${GREEN}✓ 依赖已就绪${NC}"
    fi
}

preflight_check

while true; do
    main_menu
done
