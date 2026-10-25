# Linux Gaming Stream in Proxmox LXC

> **Proxmox VE + Debian LXC + NVIDIA GPU Sharing + Headless Xorg + KDE Plasma + Sunshine & Moonlight**  
> 물리 모니터가 없는 가상화 환경(LXC)에서 NVIDIA GPU를 장치 공유(Device Sharing) 방식으로 연결하여, 가상 1080p 데스크톱과 Steam Big Picture를 실행하고 Sunshine을 통해 초저지연 하드웨어 인코딩(NVENC) 게임 스트리밍을 구축하는 올인원 솔루션입니다.

---

## 목차
1. [프로젝트 개요](#프로젝트-개요)
2. [전체 아키텍처](#전체-아키텍처)
3. [사전 준비사항 (Proxmox 호스트 설정)](#사전-준비사항-proxmox-호스트-설정)
4. [Step-by-Step 인스톨러 사용법](#step-by-step-인스톨러-사용법)
5. [세부 설치 단계별 설명](#세부-설치-단계별-설명)
6. [저장소 구조](#저장소-구조)
7. [주요 트러블슈팅 및 엔지니어링 우회책](#주요-트러블슈팅-및-엔지니어링-우회책)
8. [운영 및 진단 치트시트](#운영-및-진단-치트시트)

---

## 프로젝트 개요

일반적인 Proxmox 환경에서 원격 게이밍을 구성할 때는 보통 VM에 GPU를 독점 전달하는 **PCI Passthrough** 방식을 사용합니다. 하지만 이 방식은 호스트의 리소스 낭비가 심하고 다른 용도로 GPU를 공유하기 어렵습니다.

이 프로젝트는 **LXC 컨테이너 장치 공유(`/dev` Bind-mount)**를 채택하여 다음과 같은 이점을 제공합니다:
- **초경량 오버헤드**: VM 대비 CPU 및 RAM 오버헤드가 거의 없음
- **동적 자원 공유**: 호스트와 컨테이너가 커널 드라이버를 공유
- **Headless 모니터 에뮬레이션**: 물리 더미 플러그(HDMI/DP Dummy Plug) 없이 순수 소프트웨어 설정만으로 가상 1920x1080 60Hz/120Hz 디스플레이 생성
- **풀 하드웨어 가속**: NVIDIA GLX / Vulkan 직접 렌더링 + Sunshine NVENC(H.264) 하드웨어 인코딩 완벽 지원
- **LXC 환경 입력 한계 극복**: LXC 내부의 udev 부재로 인한 마우스/키보드/게임패드 핫플러그 미인식 문제를 전용 브릿지 데몬 및 SDL 백엔드로 해결

---

## 전체 아키텍처

```
[ Proxmox VE Host ]
 └─ Linux Kernel (NVIDIA 커널 모듈: e.g. 595.91.07)
     │
     ├─ /dev/nvidia*, /dev/dri, /dev/uinput 장치 노드 바인드 마운트
     ▼
[ Debian LXC Container (Debian 12 Bookworm / 13 Trixie) ]
 ├─ NVIDIA Userspace 라이브러리 (커널 모듈 제외, --no-kernel-module 설치)
 ├─ Xorg :0 (gaming-x.service, DFP 가짜 모니터 1920x1080@60Hz 생성)
 ├─ KDE Plasma 6 (X11 Desktop Session on :0)
 ├─ PipeWire Audio (더미/가상 스테레오 싱크)
 ├─ Sunshine Streaming Server (X11 화면 캡처 + H.264 NVENC 하드웨어 인코딩)
 ├─ sunshine-input-bridge (LXC udev 부재 해결: uinput evdev 이벤트를 XTest로 재주입)
 └─ gamescope + Steam (moonlight-steam 래퍼: SDL 게임패드 핫플러그 및 Big Picture 제어)
```

### 데이터 및 제어 흐름
1. **영상 (Video)**: Xorg(`:0`) 가상 모니터 렌더링 → Sunshine이 X11 캡처 → NVIDIA NVENC (`h264_nvenc`) 하드웨어 인코딩 → Moonlight 클라이언트로 UDP 스트리밍
2. **입력 (Input)**: Moonlight 클라이언트 입력 전송 → Sunshine 가상 uinput 생성 → `sunshine-input-bridge.py`가 X11 커서/키보드로 주입, 게임패드는 `gamescope --backend sdl`의 inotify/폴링 메커니즘을 통해 Steam 및 게임에 전달
3. **오디오 (Audio)**: 게임/데스크톱 출력 → PipeWire 가상 오디오 싱크 → Sunshine 오디오 캡처 → Moonlight 송출

---

## 사전 준비사항 (Proxmox 호스트 설정)

LXC 컨테이너가 GPU를 사용하려면 **Proxmox 호스트**에서 장치 노드 접근 권한 및 바인드 마운트를 설정해야 합니다.

### 1. 호스트 드라이버 설치
Proxmox 호스트에 NVIDIA 드라이버가 정상 설치되어 작동 중이어야 합니다 (`nvidia-smi` 정상 동작 확인).

### 2. 컨테이너 설정 파일 편집
Proxmox 호스트의 셸에서 컨테이너 설정 파일(`/etc/pve/lxc/<CTID>.conf`) 하단에 아래 내용을 추가합니다:
*(참고: [`configs/pve/pve-lxc.conf.example`](configs/pve/pve-lxc.conf.example))*

```ini
# 컨테이너 특권 모드 (디바이스 노드 바인드에 권장)
unprivileged: 0

# 1. cgroup2 디바이스 접근 권한 부여 (NVIDIA, DRI, Input, uinput, uhid)
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.cgroup2.devices.allow: c 511:* rwm
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.cgroup2.devices.allow: c 10:223 rwm
lxc.cgroup2.devices.allow: c 10:239 rwm
lxc.cgroup2.devices.allow: c 13:* rwm

# 2. 호스트의 디바이스 노드를 컨테이너 내부로 바인드 마운트
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-modeset dev/nvidia-modeset none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-caps dev/nvidia-caps none bind,optional,create=dir
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.mount.entry: /dev/uinput dev/uinput none bind,optional,create=file
lxc.mount.entry: /dev/uhid dev/uhid none bind,optional,create=file
lxc.mount.entry: /dev/input dev/input none bind,optional,create=dir
```

설정 후 Proxmox에서 해당 컨테이너를 재부팅합니다:
```bash
pct reboot <CTID>
```

---

## Step-by-Step 인스톨러 사용법

컨테이너 내부(순수 Debian 환경)에 일반 유저(또는 root)로 접속한 뒤, 본 저장소를 클론하고 `install.sh`를 실행합니다.

```bash
git clone https://github.com/<your-username>/linux_stream_in_lxc.git
cd linux_stream_in_lxc
chmod +x install.sh
```

### 전체 자동 설치 (All-in-One)
```bash
sudo ./install.sh all
```
> [!NOTE]
> 호스트 장치 검증부터 기본 패키지, 일치하는 버전의 NVIDIA userspace 드라이버 다운로드 및 설치, Xorg 설정, Sunshine 설치, 유저 데몬 등록까지 자동으로 순차 실행됩니다.

### 단계별(Step-by-Step) 수동 실행
문제가 발생하거나 설정을 세밀하게 검증하며 진행하고 싶다면 단계별로 실행할 수 있습니다:

```bash
# 0단계: 호스트 passthrough 장치 상태 검증
./install.sh step0

# 1단계: Debian 필수 패키지 설치 (Xorg, KDE, PipeWire, evdev 등)
sudo ./install.sh step1

# 2단계: 호스트 커널 드라이버와 100% 일치하는 NVIDIA Userspace 드라이버 설치
sudo ./install.sh step2

# 3단계: Headless Xorg 가상 모니터 및 udev/sudoers 권한 설정
sudo ./install.sh step3

# 4단계: Sunshine 스트리밍 서버 설치 및 설정
sudo ./install.sh step4

# 5단계: 보조 스크립트 (입력 브릿지, Steam 래퍼 등) ~/.local/bin 설치
./install.sh step5

# 6단계: Systemd 유저 서비스 등록 및 loginctl linger 활성화
sudo ./install.sh step6

# 7단계: 전체 스트리밍 환경 상태 진단
./install.sh check
```

---

## 세부 설치 단계별 설명

### Step 0: 사전 요구사항 검증
- `/proc/driver/nvidia/version`을 조회하여 호스트의 커널 드라이버 버전을 확인합니다.
- `/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-modeset`, `/dev/nvidia-uvm`, `/dev/dri/renderD*`, `/dev/uinput` 장치 노드가 정상 마운트되었는지 점검합니다. 누락된 경우 Proxmox 설정 예시를 출력하고 안전하게 중단됩니다.

### Step 1: 기본 패키지 설치
- i386 멀티아키텍처 활성화 (`dpkg --add-architecture i386` — Steam 및 32비트 게임 지원 필수).
- Xorg 코어 서버, 드라이버 유틸리티, 가상 데스크톱 컴포넌트(`plasma-desktop`, `kwin-x11`), 오디오 스택(`pipewire`, `wireplumber`), 파이썬 evdev/XTest 라이브러리를 설치합니다.

### Step 2: NVIDIA Userspace 드라이버 설치
- LXC 컨테이너 내부에는 **호스트의 커널 모듈과 메이저/마이너 버전이 완전히 동일한 userspace 라이브러리**가 설치되어야 GLX 및 NVENC가 정상 동작합니다.
- 인스톨러가 `/proc/driver/nvidia/version`에서 버전을 자동 추출(예: `595.91.07`)하여 공식 NVIDIA 서버에서 해당 버전의 `.run` 설치 파일을 다운로드합니다.
- `--no-kernel-module --install-libglvnd --install-compat32-libs -s` 플래그로 커널 모듈 빌드 없이 라이브러리만 안전하게 설치합니다.
- `/etc/vulkan/icd.d/nvidia_icd.json`을 등록하여 Vulkan 가속을 보장합니다.

### Step 3: Headless Xorg 및 권한 구성
- `lspci`에서 NVIDIA GPU의 PCI 주소를 감지하여 `BusID "PCI:X:Y:Z"` 형식으로 자동 변환합니다.
- [`configs/xorg/20-nvidia-headless.conf`](configs/xorg/20-nvidia-headless.conf)를 `/etc/X11/xorg.conf.d/`에 배치하여 물리 모니터 없이도 DFP 디스플레이(1920x1080@60Hz)를 출력하도록 합니다.
- `/etc/systemd/system/gaming-x.service` 시스템 서비스를 등록하여 디스플레이 서버를 구동합니다.
- 유저가 Xorg 서비스를 무암호로 제어할 수 있도록 `/etc/sudoers.d/99-gaming-x`를 생성합니다.

### Step 4: Sunshine 스트리밍 서버 설치
- LizardByte 공식 Cloudsmith 저장소를 등록하고 Sunshine 최신 배포본을 설치합니다.
- `sunshine.conf`에 NVENC 하드웨어 가속 인코더(`encoder = nvenc`), 한국어 로케일, x360 게임패드를 기본 적용합니다.

### Step 5: 스크립트 및 래퍼 배치
- `sunshine-input-bridge.py`: LXC의 udev 부재 문제를 해결하기 위해 Sunshine의 uinput 마우스/키보드 이벤트를 X11 XTest API로 주입하는 백그라운드 브릿지.
- `moonlight-steam`: Steam Big Picture 및 개별 게임 실행 래퍼. 게임패드 감지 후 gamescope 안에서 1080p 풀스크린을 띄웁니다.
- `stream-doctor`: 전체 스트리밍 컴포넌트 진단 및 원클릭 복구 도구.

### Step 6: Systemd 유저 서비스 등록 & Linger
- `loginctl enable-linger $USER`를 실행하여 사용자가 SSH로 로그인하지 않아도 부팅 시 유저 systemd 서비스들이 자동으로 실행되도록 보장합니다.
- `plasma-x11.service`, `sunshine.service`, `input-bridge.service`, `sunshine-steam-sync.timer`를 등록 및 활성화합니다.

---

## 저장소 구조

```
linux_stream_in_lxc/
├── AGENTS.md                  # 전체 시스템 실측 엔지니어링 히스토리 및 명세서
├── README.md                  # 프로젝트 설명 및 종합 안내서 (본 파일)
├── install.sh                 # 순수 Debian 컨테이너용 원클릭/단계별 인스톨러
├── bin/                       # 런타임 핵심 실행 스크립트 모음
│   ├── moonlight-steam        # gamescope + Steam Big Picture 실행 래퍼
│   ├── stream-doctor          # 스트리밍 세션 종합 진단 & 재시작 도구
│   ├── sunshine-display-idle.sh # 스트리밍 유휴 시 Xorg 절전 제어
│   ├── sunshine-display-up.sh   # 스트리밍 시작 시 Xorg 온디맨드 기동
│   ├── sunshine-input-bridge.py # uinput → XTest 입력 브릿지 데몬
│   └── sunshine-sync-steam-games # Steam 설치 게임 Sunshine 목록 자동 동기화
├── configs/                   # 표준 설정 파일 및 서비스 템플릿
│   ├── pve/pve-lxc.conf.example   # Proxmox 호스트 컨테이너 설정 스니펫
│   ├── xorg/20-nvidia-headless.conf # Xorg 가짜 모니터 에뮬레이션 설정
│   ├── udev/99-gaming.rules       # renderD128 및 uinput 접근 권한 규칙
│   ├── sudoers.d/99-gaming-x      # gaming-x 서비스 무암호 제어 규칙
│   ├── vulkan/nvidia_icd.json     # NVIDIA Vulkan ICD 프로파일
│   ├── sunshine/
│   │   ├── sunshine.conf.example  # Sunshine 서버 기본 설정
│   │   └── apps.json.example      # 기본 스트리밍 앱 등록 템플릿
│   └── systemd/
│       ├── system/gaming-x.service  # Xorg 시스템 데몬
│       └── user/                  # 유저 레벨 systemd 데몬 모음
│           ├── plasma-x11.service
│           ├── sunshine.service
│           ├── input-bridge.service
│           ├── sunshine-steam-sync.service & .timer
│           └── sunshine-display-idle.service & .timer
└── docs/                      # 상세 주제별 기술 분석 문서
    ├── architecture.md        # 렌더링/캡처/입력 아키텍처 상세
    ├── nvidia-lxc.md          # GPU Device Sharing 실측 데이터
    ├── sunshine.md            # Sunshine 및 인코더 분석
    └── troubleshooting.md     # 우선순위별 트러블슈팅 가이드
```

---

## 주요 트러블슈팅 및 엔지니어링 우회책

### 1. LXC 컨테이너 내부 `udev` 부재로 인한 입력 문제
- **문제**: LXC 컨테이너 내부에는 `udevd`가 실행되지 않으므로, Moonlight 클라이언트가 접속할 때 Sunshine이 동적으로 생성하는 가상 마우스/키보드/컨트롤러 장치를 Xorg가 감지하지 못함.
- **해결책**:
  - **마우스/키보드**: [`bin/sunshine-input-bridge.py`](bin/sunshine-input-bridge.py) 데몬이 `/dev/input/`을 직접 감시하다가 Sunshine 가상 장치가 생성되면 evdev 이벤트를 읽어 X11 XTest API로 커서와 키 입력을 즉각 주입.
  - **게임패드**: `moonlight-steam` 스크립트에서 gamescope 실행 시 `--backend sdl`을 명시. SDL2 라이브러리의 자체 inotify 및 폴링 메커니즘을 활성화하여 udev 없이도 엑스박스 가상 패드 핫플러그를 감지.

### 2. Sunshine NVENC 하드웨어 인코딩 실패 (Software fallback)
- **문제**: 구버전 Sunshine이나 특정 NVIDIA 드라이버 조합에서 `Driver does not support the required nvenc API version` 에러가 발생하며 CPU 소프트웨어 인코딩(libx264)으로 강제 전환되는 문제.
- **해결책**: 최신 Sunshine 빌드 내장 FFmpeg가 요구하는 NVENC SDK 버전에 맞추어 NVIDIA 드라이버를 595.91 이상으로 유지해야 함. 본 인스톨러의 `step2`가 호스트 커널 드라이버 버전을 감지해 완벽히 일치하는 드라이버를 설치하므로 버전 미스매치를 방지함.

### 3. 해상도가 1024x768로 튀는 현상
- **문제**: 물리 모니터가 없으므로 KDE Plasma의 `kscreen` 데몬이 기본 해상도를 1024x768로 임의 복원하는 문제.
- **해결책**: `20-nvidia-headless.conf`의 Modeline 및 MetaModes 설정을 통해 1920x1080@60Hz를 기본 PreferredMode로 고정.

### 4. GameMode (`gamemoderun`) 크래시
- **주의사항**: `gamemoderun`의 `libgamemodeauto.so.0` LD_PRELOAD가 LXC 환경 내에서 D-Bus 통신 실패를 일으켜 Steam 자식 프로세스들을 SIGABRT(exit 134)로 강제 종료시키는 현상이 확인되었습니다. `moonlight-steam`에서는 `gamemoderun` 사용을 엄격히 배제합니다.

---

## 운영 및 진단 치트시트

### 상태 확인 및 자가 진단
저장소에 포함된 `stream-doctor` 유틸리티로 모든 구성 요소(Xorg, 해상도, GLX, KDE, 포트, NVENC)를 한 번에 검사할 수 있습니다:

```bash
# 전체 상태 요약 확인
stream-doctor status

# 세부 컴포넌트 헬스 체크
stream-doctor check
```

### 개별 서비스 수동 제어
```bash
# Xorg 서버 제어 (root systemd)
sudo systemctl restart gaming-x.service

# 유저 서비스 제어 (user systemd)
systemctl --user restart sunshine.service
systemctl --user restart plasma-x11.service
systemctl --user restart input-bridge.service

# Sunshine 실시간 로그 확인
journalctl --user -u sunshine -f
```

### Moonlight 클라이언트 연결
1. 웹 브라우저에서 `https://<LXC_컨테이너_IP>:47990` 접속
2. 최초 관리자 계정/비밀번호 설정
3. Moonlight 클라이언트 실행 후 컨테이너 IP 입력
4. Moonlight에 표시된 4자리 PIN을 Sunshine 웹 UI의 `PIN` 메뉴에 입력하여 페어링 완료
5. **Desktop** 또는 **Steam Gaming**을 선택하여 스트리밍 시작!
