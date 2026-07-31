#!/usr/bin/env bash
#
# SSH 허용 IP 갱신.
# 관리 위치가 바뀌어(집 IP 변경, Cloud Shell 재접속 등) SSH 가 막혔을 때 실행한다.
#
#   ./ssh-allow-ip.sh              지금 이 머신의 공인 IP 로 갱신
#   ./ssh-allow-ip.sh 1.2.3.4/32   지정한 대역으로 갱신
#   ./ssh-allow-ip.sh --close      SSH 를 완전히 차단
#
# OCI API 만 사용한다. 서버에 SSH 로 들어가지 않으므로 지금 SSH 가 막혀 있어도,
# 어느 머신에서 실행하든 동작한다. 스스로를 잠글 수 없는 구조다.
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
    exit 0
fi

ok "Security List 갱신 완료: SSH 허용 = $NEW_CIDR"
echo
echo "  접속: ssh -i $SSH_KEY <계정>@$PUBLIC_IP"
echo
echo "  반영에 몇 초 걸릴 수 있습니다. 바로 안 되면 잠시 후 다시 시도하세요."

# 상태 파일 반영
tmp=$(mktemp)
jq --arg cidr "$NEW_CIDR" '.admin_cidr = $cidr' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
chmod 600 "$STATE_FILE"
