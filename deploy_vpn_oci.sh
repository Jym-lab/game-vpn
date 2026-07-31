#!/usr/bin/env bash
#
# OCI Always Free 인스턴스에 sing-box 기반 VPN(Hysteria2 + VLESS-REALITY)을 배포한다.
# deploy_glider_oci.sh 의 후속 스크립트.
#
#   변경 요지
#     - 평문 SOCKS5(1080) 제거 -> Hysteria2(UDP 443) + VLESS-REALITY(TCP 443)
#     - 방화벽 기본 정책 DROP, SSH 는 지정한 IP 에서만
#     - 월 송신량 하드 캡 + OCI 예산 알림으로 과금 사고 차단
#
# 환경변수로 조정 가능한 값은 아래 "설정" 절 참고.
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------- 설정
REGION="${REGION:-us-sanjose-1}"
DISPLAY_NAME="${DISPLAY_NAME:-gvpn-server}"
PREFIX="${PREFIX:-gvpn}"
SHAPE="${SHAPE:-VM.Standard.A1.Flex}"
OCPU_COUNT="${OCPU_COUNT:-1}"
MEMORY_GB="${MEMORY_GB:-6}"
BOOT_VOLUME_GB="${BOOT_VOLUME_GB:-50}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/gvpn_oci_key}"

HY2_PORT="${HY2_PORT:-443}"
VLESS_PORT="${VLESS_PORT:-443}"
ENABLE_VLESS="${ENABLE_VLESS:-true}"
HY2_SNI="${HY2_SNI:-www.bing.com}"
REALITY_DEST="${REALITY_DEST:-www.microsoft.com}"

# 대역폭은 Hysteria2 의 Brutal 혼잡제어가 사용하는 값이다.
# 실제 회선보다 크게 잡으면 오히려 버퍼블로트와 손실이 늘어 핑이 나빠진다.
EGRESS_MBPS="${EGRESS_MBPS:-200}"    # 서버 -> 클라이언트
INGRESS_MBPS="${INGRESS_MBPS:-100}"  # 클라이언트 -> 서버

# 월 송신량 상한. 도달하면 서버가 sing-box 를 스스로 정지시킨다.
# OCI 무료 한도가 월 10TB 이므로 2TB 를 안전 여유분으로 남기고 8TB 로 잡는다.
# (가드는 10분마다 확인하므로 그 사이에 흐르는 양까지 감안한 여유다)
TRAFFIC_LIMIT_GB="${TRAFFIC_LIMIT_GB:-8000}"

# TUN 분할 라우팅에서 프록시를 태울 프로세스. 나중에 클라이언트 설정에서 수정 가능.
GAME_PROCESS="${GAME_PROCESS:-game.exe}"

LAUNCH_RETRIES="${LAUNCH_RETRIES:-20}"
LAUNCH_RETRY_DELAY="${LAUNCH_RETRY_DELAY:-60}"

OUT_DIR="$SCRIPT_DIR/client"
STATE_FILE="$SCRIPT_DIR/.deploy-state.json"

# ---------------------------------------------------------------- 유틸
c_reset=$'\033[0m'; c_head=$'\033[1;36m'; c_warn=$'\033[1;33m'; c_err=$'\033[1;31m'; c_ok=$'\033[1;32m'
STEP=0
step() { STEP=$((STEP+1)); printf '\n%s[%d] %s%s\n' "$c_head" "$STEP" "$*" "$c_reset"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '%s  ✓ %s%s\n' "$c_ok" "$*" "$c_reset"; }
warn() { printf '%s  ! %s%s\n' "$c_warn" "$*" "$c_reset"; }
die()  { printf '%s  X %s%s\n' "$c_err" "$*" "$c_reset" >&2; exit 1; }

TMPDIR_LOCAL=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR_LOCAL"; }
trap cleanup EXIT
trap 'die "실패: ${BASH_SOURCE[0]}:${LINENO} 근처"' ERR

# ---------------------------------------------------------------- 사전 점검
step "사전 점검"
for cmd in oci jq curl ssh scp ssh-keygen openssl; do
    command -v "$cmd" >/dev/null 2>&1 || {
        case "$cmd" in
            oci) die "oci CLI 가 없습니다. 설치: bash -c \"\$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)\" 후 'oci setup config'" ;;
            *)   die "$cmd 가 없습니다. 설치 후 다시 실행하세요." ;;
        esac
    }
done
[ -f "$SCRIPT_DIR/server-setup.sh" ] || die "server-setup.sh 가 같은 디렉터리에 있어야 합니다."
ok "필수 도구 확인 완료"

# ---------------------------------------------------------------- Compartment
step "Compartment / Tenancy 확인"
if [ -n "${OCI_COMPARTMENT_ID:-}" ]; then
    COMPARTMENT_ID="$OCI_COMPARTMENT_ID"
else
    COMPARTMENT_ID=$(oci iam availability-domain list --query 'data[0]."compartment-id"' --raw-output 2>/dev/null || true)
    if [ -z "$COMPARTMENT_ID" ] && [ -f "$HOME/.oci/config" ]; then
        COMPARTMENT_ID=$(awk -F= '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$HOME/.oci/config")
    fi
fi
[ -n "$COMPARTMENT_ID" ] || die "Compartment ID 를 찾을 수 없습니다. OCI_COMPARTMENT_ID 를 지정하세요."

TENANCY_ID=""
[ -f "$HOME/.oci/config" ] && TENANCY_ID=$(awk -F= '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$HOME/.oci/config")
info "Compartment: $COMPARTMENT_ID"

HOME_REGION=$(oci iam region-subscription list --query 'data[?"is-home-region"].{r:"region-name"} | [0].r' --raw-output 2>/dev/null || true)
if [ -n "$HOME_REGION" ] && [ "$HOME_REGION" != "$REGION" ]; then
    warn "홈 리전은 '$HOME_REGION' 인데 배포 대상은 '$REGION' 입니다."
    warn "Always Free 의 A1.Flex(ARM)는 홈 리전에서만 무료입니다. 다른 리전이면 과금될 수 있습니다."
    read -r -p "    그래도 계속할까요? (yes/no) [no]: " ans
    [ "${ans:-no}" = "yes" ] || die "중단합니다."
fi

# ---------------------------------------------------------------- 관리 IP
step "SSH 허용 IP 확인"
detect_public_ip() {
    local url ip
    for url in https://checkip.amazonaws.com https://api.ipify.org https://ifconfig.me/ip; do
        ip=$(curl -fsS --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]') || continue
        [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { printf '%s' "$ip"; return 0; }
    done
    return 1
}

if [ -n "${ADMIN_CIDR:-}" ]; then
    info "환경변수로 지정된 값 사용: $ADMIN_CIDR"
else
    MY_IP=$(detect_public_ip) || die "공인 IP 자동 감지 실패. ADMIN_CIDR=1.2.3.4/32 형태로 직접 지정하세요."
    info "감지된 현재 공인 IP: $MY_IP"
    read -r -p "    SSH 를 허용할 대역 [${MY_IP}/32]: " ADMIN_CIDR
    ADMIN_CIDR="${ADMIN_CIDR:-${MY_IP}/32}"
fi
[[ "$ADMIN_CIDR" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || die "ADMIN_CIDR 형식이 잘못되었습니다: $ADMIN_CIDR"
if [ "$ADMIN_CIDR" = "0.0.0.0/0" ]; then
    warn "SSH 를 전 세계에 개방하는 설정입니다. 권장하지 않습니다."
fi
ok "SSH 허용 대역: $ADMIN_CIDR"

# ---------------------------------------------------------------- 기존 리소스 정리
step "기존 리소스 정리 (선택)"
info "이 작업은 '$REGION' 리전의 대상 Compartment 안 리소스를 전부 삭제합니다."
read -r -p "    정리하려면 DELETE 를 입력하세요 (그냥 Enter 면 건너뜀): " CLEANUP_CONFIRM
if [ "${CLEANUP_CONFIRM:-}" = "DELETE" ]; then
    SD_DIR="$TMPDIR_LOCAL/OCI-SuperDelete"
    git clone -q --depth 1 https://github.com/AnykeyNL/OCI-SuperDelete.git "$SD_DIR" \
        || die "OCI-SuperDelete 클론 실패"
    [ -f "$SD_DIR/delete.py" ] || die "delete.py 를 찾을 수 없습니다."
    ( cd "$SD_DIR" && python3 delete.py -dt -c "$COMPARTMENT_ID" -rg "$REGION" -force ) \
        || die "리소스 삭제 실패"
    info "정리 완료. 30초 대기합니다."
    sleep 30
else
    info "건너뜁니다."
fi

# ---------------------------------------------------------------- 리전/셰이프/이미지
step "리전 가용성 및 이미지 확인"
AVAILABILITY_DOMAIN=$(oci iam availability-domain list \
    --region "$REGION" --compartment-id "$COMPARTMENT_ID" \
    --query 'data[0].name' --raw-output 2>/dev/null || true)
[ -n "$AVAILABILITY_DOMAIN" ] || die "$REGION 리전을 사용할 수 없습니다."

SHAPE_OK=$(oci compute shape list \
    --compartment-id "$COMPARTMENT_ID" --availability-domain "$AVAILABILITY_DOMAIN" \
    --region "$REGION" \
    --query "data[?shape=='$SHAPE'] | [0].shape" --raw-output 2>/dev/null || true)
[ -n "$SHAPE_OK" ] || die "$REGION 에서 $SHAPE 를 사용할 수 없습니다."

IMAGE_ID=$(oci compute image list \
    --compartment-id "$COMPARTMENT_ID" \
    --operating-system "Canonical Ubuntu" --operating-system-version "24.04" \
    --shape "$SHAPE" --region "$REGION" \
    --sort-by TIMECREATED --sort-order DESC --limit 1 \
    --query 'data[0].id' --raw-output 2>/dev/null || true)
[ -n "$IMAGE_ID" ] || die "Ubuntu 24.04 ARM64 이미지를 찾을 수 없습니다."
ok "AD=$AVAILABILITY_DOMAIN / shape=$SHAPE / image=${IMAGE_ID:0:32}..."

# 무료 한도 안내
if [ "$OCPU_COUNT" -gt 4 ] || [ "$MEMORY_GB" -gt 24 ]; then
    warn "Always Free A1 한도(총 4 OCPU / 24GB)를 넘는 설정입니다. 과금됩니다."
fi
if [ "$BOOT_VOLUME_GB" -gt 200 ]; then
    warn "Always Free 블록 스토리지 한도(총 200GB)를 넘는 설정입니다."
fi

# ---------------------------------------------------------------- 네트워크
step "VCN / 게이트웨이 / 라우팅 생성"
VCN_ID=$(oci network vcn create \
    --compartment-id "$COMPARTMENT_ID" --cidr-block "10.0.0.0/16" \
    --display-name "${PREFIX}-vcn" --dns-label "${PREFIX}vcn" \
    --region "$REGION" --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)
info "VCN: $VCN_ID"

IGW_ID=$(oci network internet-gateway create \
    --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" --is-enabled true \
    --display-name "${PREFIX}-igw" --region "$REGION" --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)
info "IGW: $IGW_ID"

RT_ID=$(oci network route-table list \
    --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" --region "$REGION" \
    --query 'data[0].id' --raw-output)
oci network route-table update --rt-id "$RT_ID" --region "$REGION" --force \
    --route-rules "$(jq -nc --arg igw "$IGW_ID" \
        '[{destination:"0.0.0.0/0",destinationType:"CIDR_BLOCK",networkEntityId:$igw}]')" \
    --wait-for-state AVAILABLE > /dev/null
ok "라우팅 구성 완료"

step "Security List 생성 (필요한 포트만 개방)"
INGRESS_RULES=$(jq -nc \
    --arg admin "$ADMIN_CIDR" \
    --argjson hy2 "$HY2_PORT" \
    --argjson vless "$VLESS_PORT" \
    --argjson enable_vless "$ENABLE_VLESS" '
    [
      # SSH: 지정한 IP 에서만
      {source:$admin, protocol:"6", isStateless:false,
       description:"SSH (admin only)",
       tcpOptions:{destinationPortRange:{min:22,max:22}}},

      # Hysteria2 (QUIC/UDP). 인증 실패 시 무응답이라 포트스캔에 잡히지 않는다.
      {source:"0.0.0.0/0", protocol:"17", isStateless:false,
       description:"Hysteria2",
       udpOptions:{destinationPortRange:{min:$hy2,max:$hy2}}},

      # Path MTU Discovery. 막으면 MTU 블랙홀이 생긴다.
      {source:"0.0.0.0/0", protocol:"1", isStateless:false,
       description:"ICMP fragmentation needed",
       icmpOptions:{type:3,code:4}}
    ]
    + (if $enable_vless then
        # VLESS-REALITY. 인증 실패한 접속은 실제 웹사이트로 중계된다.
        [{source:"0.0.0.0/0", protocol:"6", isStateless:false,
          description:"VLESS-REALITY fallback",
          tcpOptions:{destinationPortRange:{min:$vless,max:$vless}}}]
       else [] end)')

SECLIST_ID=$(oci network security-list create \
    --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" \
    --display-name "${PREFIX}-seclist" --region "$REGION" \
    --egress-security-rules '[{"destination":"0.0.0.0/0","protocol":"all","isStateless":false}]' \
    --ingress-security-rules "$INGRESS_RULES" \
    --wait-for-state AVAILABLE --query 'data.id' --raw-output)
ok "Security List: $SECLIST_ID"
if [ "$ENABLE_VLESS" = "true" ]; then
    PORT_SUMMARY="UDP ${HY2_PORT} (Hysteria2) / TCP ${VLESS_PORT} (VLESS-REALITY)"
else
    PORT_SUMMARY="UDP ${HY2_PORT} (Hysteria2)"
fi
info "개방: ${PORT_SUMMARY} / TCP 22(${ADMIN_CIDR})"

SUBNET_ID=$(oci network subnet create \
    --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" \
    --cidr-block "10.0.1.0/24" --display-name "${PREFIX}-subnet" --dns-label "${PREFIX}sub" \
    --security-list-ids "$(jq -nc --arg s "$SECLIST_ID" '[$s]')" \
    --route-table-id "$RT_ID" --region "$REGION" --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)
info "Subnet: $SUBNET_ID"

# ---------------------------------------------------------------- SSH 키
step "SSH 키 준비"
if [ ! -f "$SSH_KEY" ]; then
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "gvpn-oci" >/dev/null
    ok "새 키 생성: $SSH_KEY"
else
    ok "기존 키 사용: $SSH_KEY"
fi
chmod 600 "$SSH_KEY"

# ---------------------------------------------------------------- 인스턴스
step "인스턴스 생성"
INSTANCE_ID=""
for attempt in $(seq 1 "$LAUNCH_RETRIES"); do
    if INSTANCE_ID=$(oci compute instance launch \
        --compartment-id "$COMPARTMENT_ID" \
        --availability-domain "$AVAILABILITY_DOMAIN" \
        --display-name "$DISPLAY_NAME" \
        --shape "$SHAPE" \
        --shape-config "$(jq -nc --argjson o "$OCPU_COUNT" --argjson m "$MEMORY_GB" '{ocpus:$o,memoryInGBs:$m}')" \
        --image-id "$IMAGE_ID" \
        --boot-volume-size-in-gbs "$BOOT_VOLUME_GB" \
        --subnet-id "$SUBNET_ID" \
        --assign-public-ip true \
        --ssh-authorized-keys-file "${SSH_KEY}.pub" \
        --region "$REGION" \
        --wait-for-state RUNNING \
        --query 'data.id' --raw-output 2>"$TMPDIR_LOCAL/launch.err"); then
        break
    fi
    if grep -qiE 'out of host capacity|out of capacity|InternalError|TooManyRequests' "$TMPDIR_LOCAL/launch.err"; then
        warn "용량 부족 (시도 ${attempt}/${LAUNCH_RETRIES}). ${LAUNCH_RETRY_DELAY}초 후 재시도합니다."
        INSTANCE_ID=""
        sleep "$LAUNCH_RETRY_DELAY"
    else
        cat "$TMPDIR_LOCAL/launch.err" >&2
        die "인스턴스 생성 실패"
    fi
done
[ -n "$INSTANCE_ID" ] || die "재시도 한도 내에 인스턴스를 확보하지 못했습니다. 나중에 다시 시도하세요."
ok "Instance: $INSTANCE_ID"

VNIC_ID=$(oci compute instance list-vnics --instance-id "$INSTANCE_ID" --region "$REGION" \
    --query 'data[0].id' --raw-output)
PUBLIC_IP=$(oci network vnic get --vnic-id "$VNIC_ID" --region "$REGION" \
    --query 'data."public-ip"' --raw-output)
ok "공인 IP: $PUBLIC_IP"

# 상태 저장 (IP 갱신 스크립트가 참조한다)
jq -n \
    --arg region "$REGION" --arg compartment "$COMPARTMENT_ID" \
    --arg instance "$INSTANCE_ID" --arg vcn "$VCN_ID" --arg subnet "$SUBNET_ID" \
    --arg seclist "$SECLIST_ID" --arg ip "$PUBLIC_IP" --arg admin "$ADMIN_CIDR" \
    --arg key "$SSH_KEY" --argjson hy2 "$HY2_PORT" --argjson vless "$VLESS_PORT" \
    --argjson enable_vless "$ENABLE_VLESS" \
    '{region:$region,compartment_id:$compartment,instance_id:$instance,vcn_id:$vcn,
      subnet_id:$subnet,security_list_id:$seclist,public_ip:$ip,admin_cidr:$admin,
      ssh_key:$key,hy2_port:$hy2,vless_port:$vless,vless_enabled:$enable_vless}' \
    > "$STATE_FILE"
chmod 600 "$STATE_FILE"

# ---------------------------------------------------------------- SSH 대기
step "SSH 접속 대기"
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=10 -o LogLevel=ERROR)
SSH_OK=false
for _ in $(seq 1 40); do
    if ssh "${SSH_OPTS[@]}" "ubuntu@$PUBLIC_IP" true >/dev/null 2>&1; then SSH_OK=true; break; fi
    printf '.'
    sleep 6
done
printf '\n'
if [ "$SSH_OK" != true ]; then
    die "SSH 타임아웃. ADMIN_CIDR($ADMIN_CIDR)가 현재 접속 중인 공인 IP 와 다를 수 있습니다. Security List 를 확인하세요."
fi
ok "SSH 연결됨"

# ---------------------------------------------------------------- 서버 설치
step "서버 설치 실행"
scp "${SSH_OPTS[@]}" -q "$SCRIPT_DIR/server-setup.sh" "ubuntu@$PUBLIC_IP:/tmp/server-setup.sh"
printf '%s\n' "────────────────────────────────────────────"
ssh "${SSH_OPTS[@]}" "ubuntu@$PUBLIC_IP" \
    "chmod +x /tmp/server-setup.sh && \
     ADMIN_CIDR='$ADMIN_CIDR' HY2_PORT='$HY2_PORT' VLESS_PORT='$VLESS_PORT' \
     ENABLE_VLESS='$ENABLE_VLESS' HY2_SNI='$HY2_SNI' REALITY_DEST='$REALITY_DEST' \
     EGRESS_MBPS='$EGRESS_MBPS' INGRESS_MBPS='$INGRESS_MBPS' \
     TRAFFIC_LIMIT_GB='$TRAFFIC_LIMIT_GB' SSH_USER='ubuntu' \
     PUBLIC_IP='$PUBLIC_IP' GAME_PROCESS='$GAME_PROCESS' \
     bash /tmp/server-setup.sh; rc=\$?; rm -f /tmp/server-setup.sh; exit \$rc"
printf '%s\n' "────────────────────────────────────────────"
ok "서버 설치 완료"

# ---------------------------------------------------------------- 클라이언트 설정 수집
step "클라이언트 설정 내려받기"
# 설정 파일 생성은 server-setup.sh 가 담당한다(수동 설치 시에도 동일하게 동작하도록).
# 여기서는 서버가 만들어 둔 것을 그대로 가져오기만 한다.
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
printf '*\n' > "$OUT_DIR/.gitignore"

scp "${SSH_OPTS[@]}" -q "ubuntu@$PUBLIC_IP:vpn-client/*" "$OUT_DIR/" \
    || die "클라이언트 설정 다운로드 실패"
chmod 600 "$OUT_DIR"/*

for f in clash-verge.yaml sing-box.json links.txt server-cert.pem; do
    [ -s "$OUT_DIR/$f" ] || die "$f 를 받지 못했습니다."
done
jq -e . "$OUT_DIR/sing-box.json" >/dev/null || die "sing-box.json 이 올바른 JSON 이 아닙니다."
VLESS_ON="$ENABLE_VLESS"
ok "생성됨: $OUT_DIR/{clash-verge.yaml, sing-box.json, links.txt, server-cert.pem}"

# ---------------------------------------------------------------- 검증
step "동작 확인"
UDP_COUNT=$(ssh "${SSH_OPTS[@]}" "ubuntu@$PUBLIC_IP" \
    "sudo ss -lnuH 2>/dev/null | awk -v p=':${HY2_PORT}\$' '\$5 ~ p' | wc -l" 2>/dev/null || echo 0)
if [ "${UDP_COUNT:-0}" -gt 0 ]; then
    ok "UDP ${HY2_PORT} 리스닝 확인"
else
    warn "UDP ${HY2_PORT} 리스닝을 확인하지 못했습니다. 서버에서 'sudo /opt/vpn/status.sh' 로 점검하세요."
fi
if [ "$VLESS_ON" = "true" ]; then
    TCP_COUNT=$(ssh "${SSH_OPTS[@]}" "ubuntu@$PUBLIC_IP" \
        "sudo ss -lntH 2>/dev/null | awk -v p=':${VLESS_PORT}\$' '\$4 ~ p' | wc -l" 2>/dev/null || echo 0)
    if [ "${TCP_COUNT:-0}" -gt 0 ]; then
        ok "TCP ${VLESS_PORT} 리스닝 확인"
    else
        warn "TCP ${VLESS_PORT} 리스닝을 확인하지 못했습니다."
    fi
fi

# ---------------------------------------------------------------- 예산 알림
step "OCI 예산 알림 설정 (선택)"
if [ -z "$TENANCY_ID" ]; then
    warn "~/.oci/config 에서 tenancy 를 찾지 못해 건너뜁니다."
else
    read -r -p "    비용 알림을 받을 이메일 (Enter 시 건너뜀): " BUDGET_EMAIL
    if [ -n "${BUDGET_EMAIL:-}" ]; then
        if BUDGET_ID=$(oci budgets budget create \
                --compartment-id "$TENANCY_ID" \
                --amount 1 --reset-period MONTHLY \
                --target-type COMPARTMENT \
                --targets "$(jq -nc --arg c "$COMPARTMENT_ID" '[$c]')" \
                --display-name "${PREFIX}-cost-guard" \
                --description "VPN 서버 과금 감시" \
                --query 'data.id' --raw-output 2>"$TMPDIR_LOCAL/budget.err"); then
            oci budgets alert-rule create \
                --budget-id "$BUDGET_ID" \
                --threshold 0.01 --threshold-type ABSOLUTE --type ACTUAL \
                --recipients "$BUDGET_EMAIL" \
                --display-name "${PREFIX}-cost-alert" \
                --message "OCI VPN 서버가 포함된 Compartment 에서 과금이 발생했습니다." \
                >/dev/null 2>&1 \
                && ok "예산 알림 등록 완료 (\$0.01 초과 시 $BUDGET_EMAIL 로 통지)" \
                || warn "알림 규칙 생성 실패. 콘솔에서 직접 추가하세요."
        else
            warn "예산 생성 실패(권한 부족일 수 있음). 건너뜁니다."
            sed 's/^/      /' "$TMPDIR_LOCAL/budget.err" | head -3
        fi
    else
        info "건너뜁니다."
    fi
fi

# ---------------------------------------------------------------- 요약
cat <<SUMMARY

$(printf '%s' "$c_ok")════════════════ 배포 완료 ════════════════$(printf '%s' "$c_reset")

  서버        ${PUBLIC_IP}  (${REGION})
  개방 포트   ${PORT_SUMMARY}
              TCP 22 은 ${ADMIN_CIDR} 에서만
  트래픽 상한 월 ${TRAFFIC_LIMIT_GB} GB 송신 시 서비스 자동 정지

  클라이언트 설정   ${OUT_DIR}/
  배포 상태 파일    ${STATE_FILE}

  다음 단계
    1. client/clash-verge.yaml 을 Clash Verge Rev 로 불러오기
    2. rules 절의 '${GAME_PROCESS}' 를 실제 게임 실행파일명으로 수정
    3. Tun Mode + Service Mode 활성화

  운영 명령
    상태 확인   ssh -i ${SSH_KEY} ubuntu@${PUBLIC_IP} 'sudo /opt/vpn/status.sh'
    IP 변경 시  ./ssh-allow-ip.sh

  주의
    - client/ 안의 파일에는 접속 자격증명이 들어 있습니다. 공유하지 마세요.
    - SSH 개인키는 ${SSH_KEY} 에 있습니다. 출력하지 않았습니다.
    - Always Free 전용 계정은 7일 이상 유휴한 인스턴스를 회수할 수 있습니다.

SUMMARY
