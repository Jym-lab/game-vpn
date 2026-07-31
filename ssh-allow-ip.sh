#!/usr/bin/env bash
#
# SSH 허용 IP 갱신.
# 집/회사 공인 IP 가 바뀌어 SSH 가 막혔을 때 실행한다.
#
#   ./ssh-allow-ip.sh              현재 공인 IP 로 갱신
#   ./ssh-allow-ip.sh 1.2.3.4/32   지정한 대역으로 갱신
#   ./ssh-allow-ip.sh --close      SSH 를 완전히 차단 (OCI 콘솔로만 관리)
#
# Security List 는 OCI API 로 바꾸므로 현재 SSH 가 막혀 있어도 동작한다.
# 호스트 iptables 갱신은 SSH 가 열린 뒤에 이어서 수행한다.
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/.deploy-state.json"

c_reset=$'\033[0m'; c_ok=$'\033[1;32m'; c_warn=$'\033[1;33m'; c_err=$'\033[1;31m'
ok()   { printf '%s✓ %s%s\n' "$c_ok" "$*" "$c_reset"; }
warn() { printf '%s! %s%s\n' "$c_warn" "$*" "$c_reset"; }
die()  { printf '%sX %s%s\n' "$c_err" "$*" "$c_reset" >&2; exit 1; }

[ -f "$STATE_FILE" ] || die "$STATE_FILE 이 없습니다. deploy_vpn_oci.sh 를 먼저 실행하세요."
command -v oci >/dev/null || die "oci CLI 가 필요합니다."
command -v jq  >/dev/null || die "jq 가 필요합니다."

REGION=$(jq -r .region "$STATE_FILE")
SECLIST_ID=$(jq -r .security_list_id "$STATE_FILE")
PUBLIC_IP=$(jq -r .public_ip "$STATE_FILE")
SSH_KEY=$(jq -r .ssh_key "$STATE_FILE")

CLOSE=false
NEW_CIDR="${1:-}"
if [ "$NEW_CIDR" = "--close" ]; then
    CLOSE=true
    NEW_CIDR=""
elif [ -z "$NEW_CIDR" ]; then
    for url in https://checkip.amazonaws.com https://api.ipify.org https://ifconfig.me/ip; do
        ip=$(curl -fsS --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]') || continue
        [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { NEW_CIDR="${ip}/32"; break; }
    done
    [ -n "$NEW_CIDR" ] || die "공인 IP 자동 감지 실패. 대역을 인자로 지정하세요."
fi

if [ "$CLOSE" != true ]; then
    [[ "$NEW_CIDR" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || die "CIDR 형식 오류: $NEW_CIDR"
fi

# ---- Security List 갱신 --------------------------------------------------
CURRENT=$(oci network security-list get --security-list-id "$SECLIST_ID" --region "$REGION" \
    --query 'data."ingress-security-rules"' 2>/dev/null) || die "Security List 조회 실패"

# 22번 포트 규칙만 걸러내고 새 규칙으로 대체한다.
UPDATED=$(jq -c \
    --arg cidr "${NEW_CIDR:-}" --argjson close "$([ "$CLOSE" = true ] && echo true || echo false)" '
    def is_ssh: (."tcp-options"."destination-port-range".min? // -1) == 22;
    [ .[] | select(is_ssh | not) ]
    + (if $close then [] else
        [{ source: $cidr, protocol: "6", "is-stateless": false,
           description: "SSH (admin only)",
           "tcp-options": { "destination-port-range": { min: 22, max: 22 } } }]
       end)
    ' <<<"$CURRENT")

# OCI CLI 는 입력 시 camelCase 를 요구하므로 키 이름을 되돌린다.
UPDATED=$(jq -c 'map(
      { source, protocol, isStateless: ."is-stateless", description }
      + (if ."tcp-options"  then {tcpOptions:  {destinationPortRange: ."tcp-options"."destination-port-range"}} else {} end)
      + (if ."udp-options"  then {udpOptions:  {destinationPortRange: ."udp-options"."destination-port-range"}} else {} end)
      + (if ."icmp-options" then {icmpOptions: {type: ."icmp-options".type, code: ."icmp-options".code}} else {} end)
      | with_entries(select(.value != null))
    )' <<<"$UPDATED")

oci network security-list update --security-list-id "$SECLIST_ID" --region "$REGION" --force \
    --ingress-security-rules "$UPDATED" --wait-for-state AVAILABLE >/dev/null \
    || die "Security List 갱신 실패"

if [ "$CLOSE" = true ]; then
    ok "Security List 에서 SSH(22) 를 제거했습니다."
    warn "이제 SSH 로 접속할 수 없습니다. 다시 열려면 './ssh-allow-ip.sh' 를 실행하세요."
    warn "호스트 iptables 규칙은 그대로 남지만 Security List 가 막고 있어 도달하지 않습니다."
    exit 0
fi
ok "Security List 갱신: SSH 허용 = $NEW_CIDR"

# ---- 호스트 iptables 갱신 -------------------------------------------------
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=10 -o LogLevel=ERROR)

printf '서버 방화벽 갱신을 위해 SSH 접속을 시도합니다'
CONNECTED=false
for _ in $(seq 1 15); do
    if ssh "${SSH_OPTS[@]}" "ubuntu@$PUBLIC_IP" true >/dev/null 2>&1; then CONNECTED=true; break; fi
    printf '.'
    sleep 4
done
printf '\n'
[ "$CONNECTED" = true ] || die "SSH 접속 실패. Security List 반영에 시간이 걸릴 수 있으니 잠시 후 다시 실행하세요."

ssh "${SSH_OPTS[@]}" "ubuntu@$PUBLIC_IP" "
    set -e
    sudo iptables -S INPUT | grep -- '--dport 22' | sed 's/^-A/-D/' \
        | while IFS= read -r rule; do sudo iptables \$rule; done
    sudo iptables -A INPUT -p tcp -s '$NEW_CIDR' --dport 22 -j ACCEPT
    sudo netfilter-persistent save > /dev/null
" || die "서버 iptables 갱신 실패"
ok "서버 iptables 갱신 완료"

# 상태 파일 반영
tmp=$(mktemp)
jq --arg cidr "$NEW_CIDR" '.admin_cidr = $cidr' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
chmod 600 "$STATE_FILE"
ok "완료"
