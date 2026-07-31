# OCI Always Free 게임용 VPN

해외 리전(기본 `us-sanjose-1`)의 OCI 무료 인스턴스에 sing-box 기반 VPN 서버를 배포하고,
Windows 클라이언트에서 **특정 게임 실행파일만** VPN 을 타게 만드는 구성.

기존 `deploy_glider_oci.sh`(평문 SOCKS5 + glider)를 대체한다.

---

## 무엇이 달라졌나

| | 기존 (glider) | 현재 (sing-box) |
|---|---|---|
| 프로토콜 | SOCKS5 평문 / TCP 1080 | Hysteria2 (QUIC/UDP 443) + VLESS-REALITY (TCP 443) |
| 암호화 | 없음 (인증정보도 평문) | TLS 1.3 |
| UDP | Security List 가 TCP 만 열어 **UDP 불가** | 네이티브 UDP 릴레이 |
| 스캔 노출 | SOCKS5 핸드셰이크로 프록시임이 즉시 드러남 | 인증 실패 시 무응답(UDP) / 실제 웹사이트로 중계(TCP) |
| 호스트 방화벽 | `iptables -F` + 전 정책 ACCEPT | 기본 정책 DROP, 필요한 포트만 |
| SSH | 22 전세계 개방 | 지정 IP/32 에서만, 키 인증 전용 |
| 프로세스 권한 | Docker 컨테이너(root) | 전용 시스템 계정 + systemd 샌드박스 |
| 혼잡제어 | CUBIC | BBR + fq (서버) / Brutal (터널) |
| 과금 방어 | 없음 | 월 송신량 하드 캡 + OCI 예산 알림 |
| 키 취급 | SSH 개인키를 터미널에 그대로 출력 | 출력하지 않음, ed25519 |

---

## 개방 포트

꼭 필요한 건 **UDP 443 하나**다.

| 포트 | 출처 | 용도 |
|---|---|---|
| UDP 443 | `0.0.0.0/0` | Hysteria2. 인증 실패 시 서버가 아무 응답도 하지 않아 포트스캔에 `open` 으로 잡히지 않는다 |
| TCP 443 | `0.0.0.0/0` | VLESS-REALITY 폴백. 인증 실패 트래픽은 실제 `www.microsoft.com` 으로 중계되어 정상 HTTPS 서버로 보인다 |
| TCP 22 | 지정한 IP/32 | 관리용 |
| ICMP 3/4 | `0.0.0.0/0` | Path MTU Discovery. 데이터 통로가 아니며 막으면 MTU 블랙홀이 생긴다 |

TCP 443 이 필요 없으면 `ENABLE_VLESS=false` 로 배포한다.
SSH 를 아예 닫으려면 배포 후 `./ssh-allow-ip.sh --close` (이후 관리는 OCI 콘솔의 Cloud Shell / 시리얼 콘솔).

---

## 사용법

배포 방식은 두 가지다. 결과물은 동일하다.

| | 방식 A: 수동 | 방식 B: 전자동 |
|---|---|---|
| 서버 생성 | 내가 웹 콘솔에서 | 스크립트가 |
| 필요한 것 | SSH 만 | `oci` CLI + API 키 설정 |
| 방화벽(Security List) | 콘솔에서 직접 입력 | 스크립트가 |
| 쓰는 파일 | `server-setup.sh` 하나 | `deploy_vpn_oci.sh` |

한 번만 만들 거면 **A**, 자주 지웠다 다시 만들 거면 **B** 가 편하다.

---

### 방식 A — 콘솔에서 서버를 직접 만든 경우

**1. 오라클 클라우드 콘솔에서 인스턴스 생성**

Compute → Instances → Create instance

| 항목 | 값 |
|---|---|
| Image | **Canonical Ubuntu 24.04** (Minimal 아님) |
| Shape | **VM.Standard.A1.Flex** (Ampere / ARM) |
| OCPU / Memory | **1 / 6GB** (Always Free 총 4/24 안) |
| Boot volume | **50GB** (기본값 그대로 두면 됨) |
| Public IP | **Assign a public IPv4 address** 체크 |
| SSH keys | 내 공개키 붙여넣기 또는 새로 생성해 개인키 저장 |

> "Always Free eligible" 딱지가 붙는지 확인할 것. ARM 은 **홈 리전에서만** 무료다.

**2. 스크립트 올려서 실행**

```bash
scp server-setup.sh <계정>@<서버IP>:
ssh <계정>@<서버IP>
bash server-setup.sh
```

SSH 허용 IP 와 서버 공인 IP 는 스크립트가 알아서 감지한다.
게임 실행파일명을 미리 넣고 싶으면:

```bash
GAME_PROCESS=MyGame.exe bash server-setup.sh
```

**3. 콘솔에서 방화벽(Security List) 규칙 추가**

⚠️ **이 단계를 빼먹으면 접속이 안 된다.** 서버 안 방화벽은 스크립트가 열었지만,
오라클 쪽 방화벽은 콘솔에서 열어야 한다.

Networking → Virtual Cloud Networks → 내 VCN → Subnets → 서브넷 → Security Lists → 기본 목록 → **Add Ingress Rules**

| Source | Protocol | Port / Type | 용도 |
|---|---|---|---|
| `0.0.0.0/0` | **UDP** | 443 | Hysteria2 — **필수** |
| `0.0.0.0/0` | **TCP** | 443 | VLESS-REALITY 폴백 |
| `0.0.0.0/0` | **ICMP** | Type 3, Code 4 | MTU 탐색 |

그리고 **기존에 있는 `0.0.0.0/0` → TCP 22 규칙은 삭제**하고,
`내IP/32` → TCP 22 규칙으로 바꾼다. (스크립트 마지막 출력에 내 IP 가 찍혀 있다)

**4. 설정 파일 내려받기**

```bash
scp -r <계정>@<서버IP>:vpn-client ./client
```

---

### 방식 B — 서버 생성까지 자동

**1. 사전 준비**

```bash
# oci CLI
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"
oci setup config

# 나머지
sudo apt install -y jq curl openssh-client openssl
```

**2. 배포**

```bash
chmod +x deploy_vpn_oci.sh server-setup.sh ssh-allow-ip.sh
./deploy_vpn_oci.sh
```

진행 중 물어보는 것:
- SSH 를 허용할 대역 (현재 공인 IP 를 자동 감지해 기본값으로 제시)
- 기존 리소스 정리 여부 (`DELETE` 입력 시에만 수행 — 해당 Compartment 를 통째로 비운다)
- 비용 알림을 받을 이메일 (선택)

---

어느 쪽이든 끝나면 `client/` 아래에 설정 파일이 생긴다.

```
client/
├── clash-verge.yaml   # Clash Verge Rev 용 (권장)
├── sing-box.json      # sing-box / NekoBox 용
├── links.txt          # 공유 링크 형식
└── server-cert.pem    # 서버 자체서명 인증서
```

설정 파일 생성은 `server-setup.sh` 가 담당한다. 방식 B 의 `deploy_vpn_oci.sh` 는
서버가 만들어 둔 것을 내려받기만 하므로 두 방식의 결과물이 항상 같다.

> 서버의 `~/vpn-client/` 에도 같은 파일이 남는다. 내려받은 뒤 지우고 싶으면
> `ssh <계정>@<IP> 'rm -rf ~/vpn-client'`

### 3. Windows 클라이언트

[Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev/releases) 를 설치한다.

1. **Profiles → New → Local** 에서 `client/clash-verge.yaml` 을 불러온다
2. **Settings → Tun Mode** 켜기, **Service Mode** 설치 및 켜기
   (프로세스 단위 매칭에 필요)
3. 프로필을 열어 `rules` 절의 실행파일명을 실제 게임 것으로 바꾼다

```yaml
rules:
  - PROCESS-NAME,YourGame.exe,PROXY
  - PROCESS-NAME,Launcher.exe,PROXY   # 런처가 따로 통신하면 함께 추가
  - MATCH,DIRECT
```

`MATCH,DIRECT` 가 마지막에 있으므로 **나열한 프로세스 외의 모든 트래픽은 VPN 을 타지 않는다.**
Netch 의 "프로세스 모드"와 같은 동작이고, 불필요한 트래픽이 서버로 흐르지 않아 egress 도 아낀다.

실행파일명은 작업 관리자 → 세부 정보 탭에서 확인한다.

---

## 핑에 대해

VPN 이 물리적 거리를 줄여주진 않는다. 실제로 이득이 나오는 경우는 셋이다.

1. **ISP 피어링 우회** — 한국 ISP → 미국 게임서버 직결 경로가 나쁠 때, OCI 백본을 경유하면 홉이 줄어든다. 이건 배포 후 직결 핑과 비교해봐야 안다.
2. **손실 구간 회복** — 한국↔미국 구간은 손실률이 1~3% 나오는 일이 흔하다. Hysteria2 의 Brutal 혼잡제어는 손실을 혼잡 신호로 해석하지 않아 CUBIC 대비 회복이 빠르다. 체감상 "핑은 비슷한데 튀는 게 줄어드는" 형태로 나타난다.
3. **UDP QoS 회피** — salamander 난독화로 QUIC 시그니처가 드러나지 않아 ISP 의 UDP 조절을 덜 받는다.

반대로 게임 서버가 한국/일본에 있다면 산호세 경유는 무조건 손해다.

### 대역폭 값 조정

`EGRESS_MBPS` / `INGRESS_MBPS` 는 Brutal 이 사용하는 목표 대역폭이다.
**실제 회선보다 크게 잡으면 오히려 손실과 버퍼블로트가 늘어 핑이 나빠진다.**
배포 후 실측해서 실제 값의 80~90% 로 맞추는 게 좋다.

```bash
EGRESS_MBPS=120 INGRESS_MBPS=60 ./deploy_vpn_oci.sh
```

---

## 과금 방어

무료 한도를 넘길 수 있는 현실적인 경로는 **egress 초과**뿐이다(월 10TB 무료).
방어는 세 겹이다.

1. **인증 없는 릴레이 불가** — 사전공유 비밀번호/UUID 없이는 1바이트도 중계되지 않는다.
   기존 구성의 진짜 위험은 여기였다. 오픈 프록시가 스캔에 걸리면 남의 트래픽이 내 egress 로 나간다.
2. **서버 자체 하드 캡** — `vnstat` 으로 월 송신량을 10분마다 확인하고,
   `TRAFFIC_LIMIT_GB`(기본 8000GB) 도달 시 `sing-box` 를 정지시킨다. 다음 달 1일에 자동 재개.
   무료 한도 10TB 에서 2TB 를 여유로 남긴 값이다. 가드가 10분 간격이라
   확인 사이에 흐르는 양까지 감안했다. 게임 용도라면 실제로는 월 수십 GB 수준이라
   여기 걸릴 일이 거의 없고, 이 값은 "내가 모르는 사이 뭔가 새고 있을 때"의 차단선이다.
3. **OCI 예산 알림** — Compartment 과금이 $0.01 만 발생해도 메일이 온다.

무료 한도 안에 남기 위해 스크립트가 고정한 값:

| 항목 | 값 | Always Free 한도 |
|---|---|---|
| Shape | VM.Standard.A1.Flex, 1 OCPU / 6GB | 총 4 OCPU / 24GB |
| 부트 볼륨 | 50 GB | 총 200 GB |
| 공인 IP | Ephemeral | 예약 IP 는 미사용 시 과금 대상 |

한도를 넘는 값을 넣으면 스크립트가 경고한다.

### 주의: 유휴 인스턴스 회수

Always Free **전용** 계정(유료 업그레이드를 한 적이 없는 계정)은 7일 이상 유휴한
컴퓨트 인스턴스를 Oracle 이 회수할 수 있다. 판정 기준은 CPU/네트워크/메모리 사용률이 모두 낮은 상태다.
게임할 때만 쓰는 VPN 은 여기에 걸릴 수 있다. 회수되면 인스턴스가 사라지므로,
자주 안 쓸 계획이면 재배포가 쉽도록 `client/` 와 `.deploy-state.json` 을 보관해두는 편이 낫다.

---

## 운영

```bash
# 서버 상태 (서비스, 리스닝 포트, 이번 달 트래픽, 방화벽)
ssh -i ~/.ssh/gvpn_oci_key <계정>@<IP> 'sudo /opt/vpn/status.sh'

# 로그
ssh -i ~/.ssh/gvpn_oci_key <계정>@<IP> 'sudo journalctl -u sing-box -n 100'

# 공인 IP 가 바뀌어 SSH 가 막혔을 때
./ssh-allow-ip.sh

# SSH 완전 차단
./ssh-allow-ip.sh --close
```

트래픽 상한에 걸려 서비스가 멈췄다면:

```bash
ssh ... 'sudo cat /var/lib/vpn-guard/tripped'   # 걸린 달 확인
ssh ... 'sudo rm /var/lib/vpn-guard/tripped && sudo systemctl start sing-box'
```

상한 자체를 바꾸려면 서버에서 `/etc/vpn-traffic-limit-gb` 를 수정한다.

---

## 서버 구성 요약

`server-setup.sh` 가 하는 일:

- sing-box 설치 (SagerNet APT 저장소, 실패 시 GitHub 릴리스 폴백)
- 전용 시스템 계정 `sing-box` 로 실행, systemd 샌드박스 적용
  (`ProtectSystem=full`, `NoNewPrivileges`, `CAP_NET_BIND_SERVICE` 만 보유)
- Hysteria2 자체서명 인증서 생성 → 클라이언트가 지문으로 고정 검증 (`skip-cert-verify` 미사용)
- REALITY 키쌍 생성, 위장 대상의 TLS1.3 응답을 사전 확인
- iptables 기본 정책 DROP + `-m owner` 로 sing-box 프로세스의 사설/링크로컬 대역 접근 차단
  (인증된 클라이언트라도 VCN 내부나 메타데이터 서비스 `169.254.169.254` 를 건드릴 수 없다)
- 호스트 리졸버를 공용 DNS 로 이전 (위 차단 때문에 필요)
- BBR + fq, QUIC 용 UDP 버퍼 확대, IP 포워딩 차단 등 sysctl
- SSH 강화 (키 전용, `AllowUsers ubuntu`, 포워딩 전면 차단) + fail2ban
- 보안 업데이트 자동 적용 (자동 재부팅은 끔)
- vnstat 기반 월 송신량 가드 (systemd timer)

---

## 수동으로 지정할 수 있는 값

전부 환경변수로 앞에 붙여서 준다. **아무것도 안 줘도 동작한다** — 아래는 기본값이다.

```bash
GAME_PROCESS=MyGame.exe TRAFFIC_LIMIT_GB=9000 bash server-setup.sh
```

### 자동 감지되는 값 (보통 손댈 필요 없음)

| 변수 | 감지 방법 | 언제 직접 줘야 하나 |
|---|---|---|
| `SSH_USER` | 현재 로그인 계정 (`id -un`) | `sudo` 로 실행할 때. **`root` 는 거부된다** |
| `ADMIN_CIDR` | 지금 SSH 접속해 있는 IP (`$SSH_CONNECTION`) | 다른 곳에서 관리할 때. 예: `ADMIN_CIDR=1.2.3.4/32` |
| `PUBLIC_IP` | 외부 IP 확인 서비스 | 서버가 NAT 뒤에 있거나 고정 IP 를 따로 붙였을 때 |

> ⚠️ `SSH_USER` 는 sshd 의 `AllowUsers` 에 그대로 들어간다. 여기가 틀리면 **SSH 가 영구히 막힌다.**
> 그래서 `sudo` 없이 실행하는 걸 권한다. sudo 로 돌리면 `SUDO_USER` 를 보고, 그것도 없으면 중단한다.
> 계정을 여러 개 쓰려면 설치 후 `/etc/ssh/sshd_config.d/99-hardening.conf` 의
> `AllowUsers` 줄에 공백으로 구분해 추가한다.

### 프로토콜 / 포트

| 변수 | 기본값 | 설명 |
|---|---|---|
| `HY2_PORT` | `443` | Hysteria2 UDP 포트. 바꾸면 Security List 도 같이 바꿔야 함 |
| `VLESS_PORT` | `443` | VLESS-REALITY TCP 포트 |
| `ENABLE_VLESS` | `true` | `false` 로 두면 TCP 443 을 아예 안 연다 |
| `HY2_SNI` | `www.bing.com` | 인증 실패한 접속에 보여줄 위장 사이트 |
| `REALITY_DEST` | `www.microsoft.com` | REALITY 위장 대상. TLS1.3 응답을 확인하고, 안 되면 `www.apple.com` 으로 자동 대체 |

### 속도 / 핑

| 변수 | 기본값 | 설명 |
|---|---|---|
| `EGRESS_MBPS` | `200` | 서버 → 클라이언트 |
| `INGRESS_MBPS` | `100` | 클라이언트 → 서버 |

⚠️ 실제 회선보다 **크게** 잡으면 Brutal 이 과하게 밀어붙여 손실·버퍼블로트가 늘고 **핑이 나빠진다.**
실측값의 80~90% 로 맞추는 게 좋다.

### 트래픽 / 클라이언트

| 변수 | 기본값 | 설명 |
|---|---|---|
| `TRAFFIC_LIMIT_GB` | `8000` | 월 송신량 상한. 도달 시 서비스 자동 정지, 다음 달 자동 재개 |
| `GAME_PROCESS` | `game.exe` | 생성될 설정 파일에 들어갈 프로세스명. 나중에 파일에서 고쳐도 됨 |

설치 후에 상한만 바꾸려면 서버에서:

```bash
echo 9000 | sudo tee /etc/vpn-traffic-limit-gb
```

### 방식 B 전용 (`deploy_vpn_oci.sh`)

| 변수 | 기본값 | 설명 |
|---|---|---|
| `REGION` | `us-sanjose-1` | Always Free ARM 은 **홈 리전에서만** 무료 |
| `OCPU_COUNT` / `MEMORY_GB` | `1` / `6` | Always Free 총 한도 4 / 24 |
| `BOOT_VOLUME_GB` | `50` | Always Free 총 한도 200 |
| `SSH_KEY` | `~/.ssh/gvpn_oci_key` | 없으면 ed25519 로 새로 만든다 |
| `PREFIX` | `gvpn` | VCN/서브넷 등 리소스 이름 접두사 |
| `DISPLAY_NAME` | `gvpn-server` | 인스턴스 이름 |
| `LAUNCH_RETRIES` | `20` | A1 용량 부족 시 재시도 횟수 |
| `LAUNCH_RETRY_DELAY` | `60` | 재시도 간격(초) |
| `OCI_COMPARTMENT_ID` | 자동 | 지정하면 자동 조회를 건너뛴다 |
