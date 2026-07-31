#!/usr/bin/env bash
#
# VPN 서버 설치 스크립트 (Ubuntu 24.04 ARM64 기준).
#
# 두 가지 방식으로 쓸 수 있다.
#
#   A. deploy_vpn_oci.sh 가 서버 생성부터 전부 자동으로 하고 이 파일을 올려서 실행
#   B. 오라클 클라우드 콘솔에서 직접 인스턴스를 만든 뒤, 이 파일 하나만 올려서 실행
#        scp server-setup.sh <계정>@<서버IP>:
#        ssh <계정>@<서버IP>
#        bash server-setup.sh          <- sudo 없이. 내부에서 필요할 때만 sudo 를 쓴다.
#
# B 방식이면 SSH 허용 IP, 서버 공인 IP, 로그인 계정을 알아서 감지한다.
# 끝나면 ~/vpn-client/ 에 클라이언트 설정 파일이 생성된다.
#
set -Eeuo pipefail

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[X] %s\033[0m\n' "$*" >&2; exit 1; }

HY2_PORT="${HY2_PORT:-443}"
VLESS_PORT="${VLESS_PORT:-443}"
HY2_SNI="${HY2_SNI:-www.bing.com}"
REALITY_DEST="${REALITY_DEST:-www.microsoft.com}"
EGRESS_MBPS="${EGRESS_MBPS:-200}"     # 서버 -> 클라이언트 (OCI egress)
INGRESS_MBPS="${INGRESS_MBPS:-100}"   # 클라이언트 -> 서버
TRAFFIC_LIMIT_GB="${TRAFFIC_LIMIT_GB:-8000}"
ENABLE_VLESS="${ENABLE_VLESS:-true}"
GAME_PROCESS="${GAME_PROCESS:-game.exe}"

# 이 파일은 VPN 서버(Ubuntu 인스턴스) "안에서" 도는 부품이다.
# 보통은 deploy_vpn_oci.sh 가 알아서 올려서 실행하므로 직접 실행할 일이 없다.
if ! grep -qiE '^ID(_LIKE)?=.*(ubuntu|debian)' /etc/os-release 2>/dev/null; then
    _os=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-알 수 없음}")
    if [ -n "${OCI_CLI_CLOUD_SHELL:-}" ] || [[ "$(hostname 2>/dev/null)" == *cloudshell* ]]; then
        die "$(printf '%s\n' \
            "여기는 Cloud Shell 입니다. 이 파일이 아니라 deploy_vpn_oci.sh 를 실행하세요." \
            "" \
            "    ./deploy_vpn_oci.sh" \
            "" \
            "server-setup.sh 는 VPN 서버 안에서 도는 부품이고," \
            "deploy_vpn_oci.sh 가 인스턴스를 만든 뒤 알아서 올려서 실행합니다." \
            "(기존 deploy_glider_oci.sh 의 setup-glider.sh 에 해당)")"
    fi
    die "$(printf '%s\n' \
        "Ubuntu/Debian 전용입니다. 현재: ${_os}" \
        "VPN 서버로 쓸 Ubuntu 24.04 인스턴스 안에서 실행하세요.")"
fi

# SSH 로그인 계정. sshd 의 AllowUsers 에 들어가므로 여기가 틀리면 접속이 영구히 막힌다.
# sudo 로 실행되면 id -un 이 root 가 되어버리므로 SUDO_USER 를 우선 본다.
if [ -z "${SSH_USER:-}" ]; then
    if [ "$(id -u)" -eq 0 ]; then
        SSH_USER="${SUDO_USER:-}"
        [ -n "$SSH_USER" ] || die "root 로 실행 중입니다. SSH_USER=<로그인 계정> 을 지정하거나 sudo 없이 실행하세요."
    else
        SSH_USER="$(id -un)"
    fi
fi
id "$SSH_USER" >/dev/null 2>&1 || die "계정 '$SSH_USER' 이 존재하지 않습니다."
[ "$SSH_USER" != "root" ] || die "SSH_USER 를 root 로 둘 수 없습니다. PermitRootLogin no 와 충돌해 접속이 막힙니다."

# 설정 파일을 놓을 위치는 SSH_USER 의 홈. sudo 로 돌려도 /root 로 새지 않게 한다.
USER_HOME=$(getent passwd "$SSH_USER" | cut -d: -f6)
[ -n "$USER_HOME" ] || die "계정 '$SSH_USER' 의 홈 디렉터리를 찾을 수 없습니다."

# SSH 허용 대역. 공백으로 구분해 여러 개를 줄 수 있다.
# 예: 배포하는 Cloud Shell 의 IP 와 집 고정 IP 를 동시에 허용.
# 지정이 없으면 지금 SSH 로 접속해 있는 IP 를 쓴다.
if [ -z "${ADMIN_CIDR:-}" ] && [ -n "${SSH_CONNECTION:-}" ]; then
    _client_ip="${SSH_CONNECTION%% *}"
    if [[ "$_client_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        ADMIN_CIDR="${_client_ip}/32"
    fi
fi
[ -n "${ADMIN_CIDR:-}" ] || die "SSH 허용 대역을 정할 수 없습니다. ADMIN_CIDR=1.2.3.4/32 형태로 지정하세요."

ADMIN_CIDRS=()
for _c in $ADMIN_CIDR; do
    [[ "$_c" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || die "ADMIN_CIDR 형식 오류: $_c"
    ADMIN_CIDRS+=("$_c")
done
[ "${#ADMIN_CIDRS[@]}" -gt 0 ] || die "유효한 SSH 허용 대역이 없습니다."

# 서버 공인 IP: 클라이언트 설정 파일에 넣을 접속 주소.
if [ -z "${PUBLIC_IP:-}" ]; then
    for _u in https://checkip.amazonaws.com https://api.ipify.org https://ifconfig.me/ip; do
        PUBLIC_IP=$(curl -fsS --max-time 8 "$_u" 2>/dev/null | tr -d '[:space:]') || PUBLIC_IP=""
        [[ "$PUBLIC_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && break
        PUBLIC_IP=""
    done
fi
[ -n "$PUBLIC_IP" ] || die "서버 공인 IP 감지 실패. PUBLIC_IP=1.2.3.4 로 지정하세요."

echo "SSH 허용 대역 : $ADMIN_CIDR"
echo "서버 공인 IP  : $PUBLIC_IP"
echo "설치 사용자   : $SSH_USER"

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------- 1. 패키지
log "[1/11] 패키지 설치"
# iptables-persistent 가 대화형 프롬프트를 띄우지 않도록 미리 응답
echo 'iptables-persistent iptables-persistent/autosave_v4 boolean false' | sudo debconf-set-selections
echo 'iptables-persistent iptables-persistent/autosave_v6 boolean false' | sudo debconf-set-selections

sudo apt-get update -qq
sudo apt-get -y -qq -o Dpkg::Options::=--force-confold upgrade
sudo apt-get install -y -qq \
    curl ca-certificates gnupg jq openssl \
    iptables iptables-persistent \
    vnstat fail2ban python3-systemd unattended-upgrades

# ---------------------------------------------------------------- 2. sing-box
log "[2/11] sing-box 설치"
install_singbox_apt() {
    sudo install -d -m 0755 /etc/apt/keyrings
    sudo curl -fsSL --retry 3 https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
    sudo chmod a+r /etc/apt/keyrings/sagernet.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/sagernet.asc] https://deb.sagernet.org * *" \
        | sudo tee /etc/apt/sources.list.d/sagernet.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq sing-box
}

install_singbox_github() {
    warn "APT 저장소 설치 실패. GitHub 릴리스에서 직접 설치합니다."
    local ver url tmp
    ver=$(curl -fsSL --retry 3 https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name' | sed 's/^v//')
    [ -n "$ver" ] && [ "$ver" != "null" ] || die "sing-box 최신 버전을 확인할 수 없습니다."
    url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-arm64.tar.gz"
    tmp=$(mktemp -d)
    curl -fsSL --retry 3 "$url" -o "$tmp/sb.tar.gz" || die "sing-box 다운로드 실패: $url"
    tar -xzf "$tmp/sb.tar.gz" -C "$tmp" --strip-components=1
    sudo install -m 0755 "$tmp/sing-box" /usr/local/bin/sing-box
    rm -rf "$tmp"
}

install_singbox_apt || install_singbox_github
SB_BIN=$(command -v sing-box) || die "sing-box 바이너리를 찾을 수 없습니다."
echo "sing-box: $SB_BIN ($($SB_BIN version | head -1))"

# 전용 시스템 계정 (root 로 돌리지 않는다)
if ! id -u sing-box >/dev/null 2>&1; then
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin sing-box
fi
sudo install -d -m 0750 -o sing-box -g sing-box /etc/sing-box
sudo install -d -m 0750 -o sing-box -g sing-box /var/lib/sing-box

# ---------------------------------------------------------------- 3. 자격증명
log "[3/11] 자격증명 및 인증서 생성"
# 16진수만 사용한다: URL/YAML/JSON 어디에 넣어도 이스케이프가 필요 없다.
HY2_PASSWORD=$(openssl rand -hex 16)
HY2_OBFS_PASSWORD=$(openssl rand -hex 16)
VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
REALITY_SHORT_ID=$(openssl rand -hex 8)

# REALITY 위장 대상이 실제로 TLS1.3 로 응답하는지 확인
if ! echo | timeout 10 openssl s_client -connect "${REALITY_DEST}:443" -servername "$REALITY_DEST" -tls1_3 >/dev/null 2>&1; then
    warn "${REALITY_DEST} 가 TLS1.3 으로 응답하지 않습니다. www.apple.com 으로 대체합니다."
    REALITY_DEST="www.apple.com"
fi

REALITY_KEYS=$("$SB_BIN" generate reality-keypair)
REALITY_PRIVATE_KEY=$(awk -F': *' '/PrivateKey/{print $2}' <<<"$REALITY_KEYS")
REALITY_PUBLIC_KEY=$(awk -F': *' '/PublicKey/{print $2}' <<<"$REALITY_KEYS")
[ -n "$REALITY_PRIVATE_KEY" ] && [ -n "$REALITY_PUBLIC_KEY" ] || die "REALITY 키 생성 실패"

# Hysteria2 용 자체서명 인증서. 클라이언트는 이 인증서를 핀 고정해서 검증한다.
sudo openssl ecparam -genkey -name prime256v1 -out /etc/sing-box/key.pem 2>/dev/null
sudo openssl req -new -x509 -days 3650 \
    -key /etc/sing-box/key.pem -out /etc/sing-box/cert.pem \
    -subj "/CN=${HY2_SNI}" -addext "subjectAltName=DNS:${HY2_SNI}" 2>/dev/null
sudo chown sing-box:sing-box /etc/sing-box/key.pem /etc/sing-box/cert.pem
sudo chmod 0600 /etc/sing-box/key.pem /etc/sing-box/cert.pem

CERT_SHA256=$(sudo openssl x509 -in /etc/sing-box/cert.pem -noout -fingerprint -sha256 \
    | cut -d= -f2 | tr -d ':' | tr 'A-Z' 'a-z')

# ---------------------------------------------------------------- 4. DNS
log "[4/11] 리졸버 설정"
# OCI 기본 리졸버(169.254.169.254)는 메타데이터 서비스와 같은 주소다.
# sing-box 의 아웃바운드에서 링크로컬 대역을 통째로 차단할 것이므로
# 호스트 리졸버를 공용 DNS 로 옮겨둔다.
sudo install -d -m 0755 /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/99-vpn.conf > /dev/null <<'RESOLVED_EOF'
[Resolve]
DNS=1.1.1.1 1.0.0.1 8.8.8.8
FallbackDNS=9.9.9.9
DNSStubListener=yes
RESOLVED_EOF
sudo systemctl restart systemd-resolved

# ---------------------------------------------------------------- 5. 설정 파일
log "[5/11] sing-box 설정 생성"
VLESS_INBOUND=""
if [ "$ENABLE_VLESS" = "true" ]; then
    VLESS_INBOUND=$(cat <<VLESS_EOF
    ,{
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${VLESS_PORT},
      "users": [
        { "name": "primary", "uuid": "${VLESS_UUID}", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_DEST}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${REALITY_DEST}", "server_port": 443 },
          "private_key": "${REALITY_PRIVATE_KEY}",
          "short_id": ["${REALITY_SHORT_ID}"]
        }
      }
    }
VLESS_EOF
)
fi

# dns 블록은 일부러 비워둔다. sing-box 버전 간 dns 스키마 변경이 잦아서
# 호스트 리졸버(127.0.0.53)를 쓰는 편이 업그레이드에 안전하다.
sudo tee /etc/sing-box/config.json > /dev/null <<CONFIG_EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "up_mbps": ${EGRESS_MBPS},
      "down_mbps": ${INGRESS_MBPS},
      "ignore_client_bandwidth": false,
      "users": [
        { "name": "primary", "password": "${HY2_PASSWORD}" }
      ],
      "obfs": {
        "type": "salamander",
        "password": "${HY2_OBFS_PASSWORD}"
      },
      "masquerade": "https://${HY2_SNI}/",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/key.pem"
      }
    }${VLESS_INBOUND}
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
CONFIG_EOF

sudo chown sing-box:sing-box /etc/sing-box/config.json
sudo chmod 0600 /etc/sing-box/config.json
sudo -u sing-box "$SB_BIN" check -C /etc/sing-box || die "sing-box 설정 검증 실패"

# ---------------------------------------------------------------- 6. 서비스
log "[6/11] systemd 서비스 등록"
# 패키지가 제공하는 유닛 대신 우리 유닛을 /etc 에 두어 버전에 관계없이 동일하게 동작시킨다.
sudo tee /etc/systemd/system/sing-box.service > /dev/null <<UNIT_EOF
[Unit]
Description=sing-box VPN service
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=sing-box
Group=sing-box
ExecStart=${SB_BIN} -D /var/lib/sing-box -C /etc/sing-box run
Restart=on-failure
RestartSec=5s

AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
PrivateTmp=true
PrivateDevices=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
ReadWritePaths=/var/lib/sing-box
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT_EOF

sudo systemctl daemon-reload
sudo systemctl enable --now sing-box
sleep 3
sudo systemctl is-active --quiet sing-box || {
    sudo journalctl -u sing-box -n 40 --no-pager
    die "sing-box 기동 실패"
}

# ---------------------------------------------------------------- 7. 커널 튜닝
log "[7/11] 커널 파라미터 튜닝"
sudo tee /etc/sysctl.d/99-vpn-tuning.conf > /dev/null <<'SYSCTL_EOF'
# --- 혼잡제어: 손실이 잦은 장거리 구간에서 CUBIC 보다 회복이 빠르다
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- QUIC(Hysteria2)은 UDP 소켓 버퍼가 작으면 패킷을 흘린다
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# --- TCP 버퍼 / 지연
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fin_timeout = 15

# --- 보안 (라우터가 아니므로 포워딩은 끈다)
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_ra = 0

fs.file-max = 1000000
SYSCTL_EOF
sudo sysctl -q -p /etc/sysctl.d/99-vpn-tuning.conf
echo "혼잡제어: $(sysctl -n net.ipv4.tcp_congestion_control) / qdisc: $(sysctl -n net.core.default_qdisc)"

# ---------------------------------------------------------------- 8. 방화벽
log "[8/11] 방화벽 구성 (기본 정책 DROP)"
SB_UID=$(id -u sing-box)

# 순서 주의: ESTABLISHED 허용을 먼저 넣은 뒤에 정책을 DROP 으로 바꿔야
# 현재 SSH 세션이 끊기지 않는다.
# -F 는 사용자 정의 체인까지 포함해 filter 테이블 전체를 비운다.
# 그래야 fail2ban 이 이미 만들어 둔 체인도 -X 로 지울 수 있다.
sudo iptables -F
sudo iptables -X || true
sudo iptables -t nat -F 2>/dev/null || true

sudo iptables -A INPUT -i lo -j ACCEPT
sudo iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
sudo iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
# Path MTU Discovery 용. 막으면 MTU 블랙홀이 생긴다.
sudo iptables -A INPUT -p icmp --icmp-type destination-unreachable -j ACCEPT
sudo iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 2/s -j ACCEPT
# SSH 출발지 제한은 OCI Security List 한 곳에서만 한다.
# 오라클이 VNIC 단에서 막으므로 패킷이 VM 에 닿지도 않고, API 로 언제든 바꿀 수 있다.
# 호스트 iptables 에서까지 출발지를 묶으면, 관리 위치가 바뀔 때마다
# "규칙을 고치려면 서버에 들어가야 하고, 들어가려면 규칙을 고쳐야 하는" 순환에 빠진다.
# (Cloud Shell 은 세션마다 IP 가 바뀌므로 특히 그렇다)
# 무차별 대입은 키 전용 인증 + fail2ban 이 막는다.
sudo iptables -A INPUT -p tcp --dport 22 -j ACCEPT
sudo iptables -A INPUT -p udp --dport "$HY2_PORT" -j ACCEPT
if [ "$ENABLE_VLESS" = "true" ]; then
    sudo iptables -A INPUT -p tcp --dport "$VLESS_PORT" -j ACCEPT
fi

# sing-box 가 사설/링크로컬 대역으로 나가지 못하게 막는다.
# 인증된 클라이언트라도 VCN 내부나 메타데이터 서비스(169.254.169.254)를
# 프록시 경유로 건드릴 수 없게 하는 SSRF 차단이다.
for net in 169.254.0.0/16 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10; do
    sudo iptables -A OUTPUT -m owner --uid-owner "$SB_UID" -d "$net" \
        -j REJECT --reject-with icmp-admin-prohibited
done

sudo iptables -P INPUT DROP
sudo iptables -P FORWARD DROP
sudo iptables -P OUTPUT ACCEPT

sudo ip6tables -F
sudo ip6tables -X || true
sudo ip6tables -A INPUT -i lo -j ACCEPT
sudo ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
sudo ip6tables -A INPUT -p ipv6-icmp -j ACCEPT
sudo ip6tables -A INPUT -p udp --dport "$HY2_PORT" -j ACCEPT
if [ "$ENABLE_VLESS" = "true" ]; then
    sudo ip6tables -A INPUT -p tcp --dport "$VLESS_PORT" -j ACCEPT
fi
for net in fc00::/7 fe80::/10; do
    sudo ip6tables -A OUTPUT -m owner --uid-owner "$SB_UID" -d "$net" -j REJECT
done
sudo ip6tables -P INPUT DROP
sudo ip6tables -P FORWARD DROP
sudo ip6tables -P OUTPUT ACCEPT

sudo netfilter-persistent save > /dev/null
echo "SSH 허용 대역: $ADMIN_CIDR"

# ---------------------------------------------------------------- 9. SSH 강화
log "[9/11] SSH 강화"
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf > /dev/null <<SSHD_EOF
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
ClientAliveInterval 60
ClientAliveCountMax 3
AllowUsers ${SSH_USER}
SSHD_EOF
sudo sshd -t && sudo systemctl reload ssh

# SSH 가 내 IP 로만 열려 있으므로 fail2ban 의 실효는 낮지만 심층방어로 남겨둔다.
sudo tee /etc/fail2ban/jail.d/sshd.local > /dev/null <<'F2B_EOF'
[sshd]
enabled  = true
backend  = systemd
maxretry = 3
findtime = 10m
bantime  = 1h
F2B_EOF
# 위에서 방화벽을 초기화하며 fail2ban 체인도 지워졌으므로 restart 로 다시 만들게 한다.
sudo systemctl enable fail2ban >/dev/null 2>&1 || true
sudo systemctl restart fail2ban >/dev/null 2>&1 || warn "fail2ban 기동 실패(무시 가능)"

# ---------------------------------------------------------------- 10. 자동 보안 업데이트
log "[10/11] 자동 보안 업데이트"
sudo tee /etc/apt/apt.conf.d/51-vpn-unattended > /dev/null <<'UU_EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
UU_EOF
sudo systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true

# ---------------------------------------------------------------- 11. 트래픽 가드
log "[11/11] 트래픽 상한 가드 설치 (${TRAFFIC_LIMIT_GB} GB/월)"
sudo systemctl enable --now vnstat >/dev/null 2>&1 || true
sudo install -d -m 0755 /opt/vpn /var/lib/vpn-guard

sudo tee /opt/vpn/traffic-guard.sh > /dev/null <<'GUARD_EOF'
#!/usr/bin/env bash
# 이번 달 송신량이 상한을 넘으면 sing-box 를 정지시킨다.
# OCI 무료 한도(월 10TB egress)를 넘겨 과금되는 사고를 막기 위한 하드 가드.
set -euo pipefail

LIMIT_GB=$(cat /etc/vpn-traffic-limit-gb 2>/dev/null || echo 8000)
STATE_DIR=/var/lib/vpn-guard
TRIP_FILE="$STATE_DIR/tripped"
mkdir -p "$STATE_DIR"

IFACE=$(ip -o -4 route show to default | awk '{print $5; exit}')
[ -n "$IFACE" ] || exit 0

JSON=$(vnstat --json m -i "$IFACE" 2>/dev/null) || exit 0
TX=$(jq -r '(.interfaces[0].traffic.month // .interfaces[0].traffic.months // [])[-1].tx // 0' <<<"$JSON")
YM=$(jq -r '((.interfaces[0].traffic.month // .interfaces[0].traffic.months // [])[-1].date // {}) | "\(.year)-\(.month)"' <<<"$JSON")
[ -n "$TX" ] || exit 0

# vnstat 은 바이트 단위. 클라우드 사업자 기준과 맞추려고 10진 GB 를 쓴다.
TX_GB=$(( TX / 1000000000 ))

if [ -f "$TRIP_FILE" ]; then
    if [ "$(cat "$TRIP_FILE")" != "$YM" ]; then
        logger -t vpn-guard "새 달($YM) 시작. sing-box 를 다시 시작합니다."
        rm -f "$TRIP_FILE"
        systemctl start sing-box || true
    fi
    exit 0
fi

if [ "$TX_GB" -ge "$LIMIT_GB" ]; then
    logger -t vpn-guard "송신량 ${TX_GB}GB 가 상한 ${LIMIT_GB}GB 도달. sing-box 를 정지합니다."
    systemctl stop sing-box || true
    echo "$YM" > "$TRIP_FILE"
elif [ "$TX_GB" -ge $(( LIMIT_GB * 80 / 100 )) ]; then
    logger -t vpn-guard "경고: 송신량 ${TX_GB}GB (상한 ${LIMIT_GB}GB 의 80% 초과)"
fi
GUARD_EOF
sudo chmod 0755 /opt/vpn/traffic-guard.sh
echo "$TRAFFIC_LIMIT_GB" | sudo tee /etc/vpn-traffic-limit-gb > /dev/null

sudo tee /etc/systemd/system/vpn-traffic-guard.service > /dev/null <<'GSVC_EOF'
[Unit]
Description=VPN monthly egress guard

[Service]
Type=oneshot
ExecStart=/opt/vpn/traffic-guard.sh
GSVC_EOF

sudo tee /etc/systemd/system/vpn-traffic-guard.timer > /dev/null <<'GTMR_EOF'
[Unit]
Description=Run VPN egress guard every 10 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
GTMR_EOF

sudo systemctl daemon-reload
sudo systemctl enable --now vpn-traffic-guard.timer >/dev/null

# 상태 확인용 헬퍼
sudo tee /opt/vpn/status.sh > /dev/null <<'STATUS_EOF'
#!/usr/bin/env bash
echo "=== sing-box ==="
systemctl is-active sing-box && systemctl show sing-box -p ActiveEnterTimestamp --value
echo
echo "=== 리스닝 포트 ==="
ss -lntup 2>/dev/null | grep -E 'sing-box|LISTEN' | head -20
echo
echo "=== 이번 달 트래픽 ==="
vnstat -m | tail -5
echo "상한: $(cat /etc/vpn-traffic-limit-gb 2>/dev/null || echo '-') GB"
[ -f /var/lib/vpn-guard/tripped ] && echo "!! 상한 도달로 서비스가 정지된 상태입니다."
echo
echo "=== 방화벽 INPUT ==="
sudo iptables -S INPUT
STATUS_EOF
sudo chmod 0755 /opt/vpn/status.sh

# ---------------------------------------------------------------- 클라이언트 설정
log "클라이언트 설정 파일 생성"

OUT_DIR="$USER_HOME/vpn-client"
sudo install -d -m 700 -o "$SSH_USER" -g "$(id -gn "$SSH_USER")" "$OUT_DIR"

sudo cp /etc/sing-box/cert.pem "$OUT_DIR/server-cert.pem"
sudo chown "$SSH_USER" "$OUT_DIR/server-cert.pem"
sudo chmod 600 "$OUT_DIR/server-cert.pem"

# hysteria2 공식 클라이언트가 쓰는 콜론 구분 대문자 지문
CERT_PIN=$(openssl x509 -in "$OUT_DIR/server-cert.pem" -noout -fingerprint -sha256 | cut -d= -f2)

# ---- Clash Verge Rev (mihomo) ----
{
cat <<YAML_EOF
# Clash Verge Rev (mihomo) 설정
#   Profiles -> New -> Local 로 이 파일을 불러온 뒤,
#   Settings 에서 Tun Mode 와 Service Mode 를 켜면 프로세스 단위 분할이 동작한다.
#
# 프록시를 태울 프로세스는 맨 아래 rules 절에서 조정한다.
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: false
external-controller: 127.0.0.1:9090
unified-delay: true
tcp-concurrent: true
find-process-mode: strict

tun:
  enable: true
  stack: mixed
  auto-route: true
  auto-detect-interface: true
  mtu: 1408
  dns-hijack:
    - any:53

dns:
  enable: true
  ipv6: false
  # 게임 클라이언트는 fake-ip 와 궁합이 나쁜 경우가 있어 redir-host 를 쓴다.
  enhanced-mode: redir-host
  nameserver:
    - 1.1.1.1
    - 8.8.8.8

proxies:
  - name: "OCI-HY2"
    type: hysteria2
    server: ${PUBLIC_IP}
    port: ${HY2_PORT}
    password: "${HY2_PASSWORD}"
    obfs: salamander
    obfs-password: "${HY2_OBFS_PASSWORD}"
    sni: ${HY2_SNI}
    # 자체서명 인증서를 지문으로 고정한다. skip-cert-verify 를 켜면 안 된다.
    skip-cert-verify: false
    fingerprint: ${CERT_SHA256}
    up: "${INGRESS_MBPS} Mbps"
    down: "${EGRESS_MBPS} Mbps"
    udp: true
YAML_EOF

GROUP_MEMBERS='      - "OCI-HY2"'
if [ "$ENABLE_VLESS" = "true" ]; then
    GROUP_MEMBERS+=$'\n      - "OCI-REALITY"'
cat <<YAML_EOF

  - name: "OCI-REALITY"
    type: vless
    server: ${PUBLIC_IP}
    port: ${VLESS_PORT}
    uuid: ${VLESS_UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${REALITY_DEST}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${REALITY_SHORT_ID}
YAML_EOF
fi

cat <<YAML_EOF

proxy-groups:
  - name: PROXY
    type: fallback
    proxies:
${GROUP_MEMBERS}
    url: "http://www.gstatic.com/generate_204"
    interval: 300

rules:
  # 여기 나열된 프로세스만 VPN 을 탄다. 나머지는 전부 직결.
  - PROCESS-NAME,${GAME_PROCESS},PROXY
  - MATCH,DIRECT
YAML_EOF
} > "$OUT_DIR/clash-verge.yaml"

# ---- sing-box / NekoBox ----
# dns 절은 일부러 넣지 않는다. 버전 간 스키마 변경 영향을 받지 않기 위해서다.
jq -n \
    --arg ip "$PUBLIC_IP" --argjson hy2port "$HY2_PORT" --argjson vlessport "$VLESS_PORT" \
    --arg pw "$HY2_PASSWORD" --arg obfs "$HY2_OBFS_PASSWORD" --arg sni "$HY2_SNI" \
    --argjson up "$INGRESS_MBPS" --argjson down "$EGRESS_MBPS" \
    --rawfile cert "$OUT_DIR/server-cert.pem" \
    --argjson vless_on "$ENABLE_VLESS" --arg uuid "$VLESS_UUID" \
    --arg pbk "$REALITY_PUBLIC_KEY" --arg sid "$REALITY_SHORT_ID" --arg rsni "$REALITY_DEST" \
    --arg proc "$GAME_PROCESS" '
{
  log: { level: "warn" },
  inbounds: [
    { type:"tun", tag:"tun-in", address:["172.19.0.1/30"], mtu:1408,
      auto_route:true, strict_route:true, stack:"mixed" }
  ],
  outbounds: (
    [ { type:"hysteria2", tag:"proxy", server:$ip, server_port:$hy2port,
        password:$pw, up_mbps:$up, down_mbps:$down,
        obfs:{ type:"salamander", password:$obfs },
        tls:{ enabled:true, server_name:$sni,
              certificate:($cert | rtrimstr("\n") | split("\n")) } } ]
    + (if $vless_on then
        [ { type:"vless", tag:"vless-fallback", server:$ip, server_port:$vlessport,
            uuid:$uuid, flow:"xtls-rprx-vision",
            tls:{ enabled:true, server_name:$rsni,
                  utls:{ enabled:true, fingerprint:"chrome" },
                  reality:{ enabled:true, public_key:$pbk, short_id:$sid } } } ]
       else [] end)
    + [ { type:"direct", tag:"direct" } ]
  ),
  route: {
    rules: [ { process_name:[$proc], outbound:"proxy" } ],
    final: "direct",
    auto_detect_interface: true
  }
}' > "$OUT_DIR/sing-box.json"

# ---- 공유 링크 ----
{
    printf 'Hysteria2 (권장)\n'
    printf 'hysteria2://%s@%s:%s/?sni=%s&obfs=salamander&obfs-password=%s&pinSHA256=%s&insecure=1#OCI-HY2\n' \
        "$HY2_PASSWORD" "$PUBLIC_IP" "$HY2_PORT" "$HY2_SNI" "$HY2_OBFS_PASSWORD" "$CERT_PIN"
    printf '\n'
    printf '  주의: 링크에는 인증서를 담을 수 없어 insecure=1 이 붙습니다.\n'
    printf '  pinSHA256 을 지원하는 클라이언트가 아니라면 clash-verge.yaml 또는\n'
    printf '  sing-box.json 을 쓰세요. 두 파일은 인증서를 고정 검증합니다.\n'
    if [ "$ENABLE_VLESS" = "true" ]; then
        printf '\nVLESS-REALITY (폴백)\n'
        printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#OCI-REALITY\n' \
            "$VLESS_UUID" "$PUBLIC_IP" "$VLESS_PORT" "$REALITY_DEST" "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID"
    fi
} > "$OUT_DIR/links.txt"

sudo chown "$SSH_USER" "$OUT_DIR"/*
sudo chmod 600 "$OUT_DIR"/*

# 재생성이 필요할 때를 대비해 원본 값도 남긴다 (root 전용)
sudo tee /root/client-params.json > /dev/null <<PARAMS_EOF
{
  "public_ip": "${PUBLIC_IP}",
  "hy2_port": ${HY2_PORT},
  "hy2_password": "${HY2_PASSWORD}",
  "hy2_obfs_password": "${HY2_OBFS_PASSWORD}",
  "hy2_sni": "${HY2_SNI}",
  "cert_sha256": "${CERT_SHA256}",
  "vless_enabled": ${ENABLE_VLESS},
  "vless_port": ${VLESS_PORT},
  "vless_uuid": "${VLESS_UUID}",
  "reality_public_key": "${REALITY_PUBLIC_KEY}",
  "reality_short_id": "${REALITY_SHORT_ID}",
  "reality_sni": "${REALITY_DEST}",
  "egress_mbps": ${EGRESS_MBPS},
  "ingress_mbps": ${INGRESS_MBPS},
  "traffic_limit_gb": ${TRAFFIC_LIMIT_GB}
}
PARAMS_EOF
sudo chmod 0600 /root/client-params.json

# ---------------------------------------------------------------- 안내
PORT_SUMMARY="UDP ${HY2_PORT} (Hysteria2)"
if [ "$ENABLE_VLESS" = "true" ]; then
    PORT_SUMMARY="${PORT_SUMMARY} / TCP ${VLESS_PORT} (VLESS-REALITY)"
fi

cat <<FINAL_EOF

════════════════ 서버 설치 완료 ════════════════

  서버 주소   ${PUBLIC_IP}
  개방 포트   ${PORT_SUMMARY}
              TCP 22 은 ${ADMIN_CIDR} 에서만
  트래픽 상한 월 ${TRAFFIC_LIMIT_GB} GB 송신 시 서비스 자동 정지

  클라이언트 설정 파일: ${OUT_DIR}/
      clash-verge.yaml    <- Clash Verge Rev 용 (권장)
      sing-box.json       <- sing-box / NekoBox 용
      links.txt           <- 공유 링크 형식
      server-cert.pem     <- 서버 인증서

  ★ 오라클 클라우드 콘솔에서 아래 인바운드 규칙을 반드시 추가하세요.
    (Networking -> VCN -> Subnet -> Security List -> Add Ingress Rules)

      Source 0.0.0.0/0   | UDP  | Dest. Port 443    <- 필수
FINAL_EOF
if [ "$ENABLE_VLESS" = "true" ]; then
    echo "      Source 0.0.0.0/0   | TCP  | Dest. Port 443    <- 폴백"
fi
echo "      Source 0.0.0.0/0   | ICMP | Type 3, Code 4    <- MTU 탐색"
for _c in "${ADMIN_CIDRS[@]}"; do
    echo "      Source ${_c} | TCP  | Dest. Port 22     <- SSH (기존 0.0.0.0/0 규칙은 삭제)"
done
cat <<FINAL_EOF

  ★ 내 PC 로 설정 파일 내려받기 (내 PC 터미널에서 실행):

      scp -r ${SSH_USER}@${PUBLIC_IP}:vpn-client ./client

  상태 확인:  sudo /opt/vpn/status.sh

FINAL_EOF
