# Architecture — 실제 구조 (2026-09-18 실측)

> `AGENTS.md`의 요약본이 아니라 구조 이해용 상세 문서. 모든 값은 LXC 내부 실측.

## 전체 경로 (부팅 → 스트리밍)

```
Proxmox Host (kernel 7.0.14-12-pve, NVIDIA kernel module 595.58.03)
 └─ LXC sunshine (Debian 13.7, privileged 정황, CTID 추정 3001 — NOT VERIFIED)
     ├─ /dev bind-mount: nvidia0/nvidiactl/nvidia-modeset/nvidia-uvm(+tools)/nvidia-caps/dri/input/uinput/uhid
     ├─ NVIDIA userspace 595.58.03 (nvidia-installer --no-kernel-module, 2026-09-13)
     ├─ system: gaming-x.service → /usr/bin/Xorg :0 (root, nvidia, DFP-0 fake 1920x1080 conf, 실제 모드 1024x768)
     ├─ system: sddm.service (disabled이나 active — 역할 NOT VERIFIED, 건드리지 말 것)
     ├─ user@1000: pipewire/wireplumber/pipewire-pulse (Dummy Output만)
     ├─ user@1000: plasma-x11.service → dbus-run-session startplasma-x11 → kwin_x11 + plasmashell 6.3.6
     ├─ user@1000: sunshine.service → /usr/bin/sunshine (DISPLAY=:0, X11 capture, software libx264 — NVENC 실패)
     ├─ user@1000: input-bridge.service → sunshine-input-bridge.py (uinput evdev → XTest :0)
     └─ apps: Steam (silent) + gamescope 3.16.28 + moonlight-steam + Firefox
```

## Host vs LXC 책임 분리

| 계층 | Host | LXC |
|---|---|---|
| kernel/NVIDIA kernel module | 소유 (595.58.03) | 공유해서 사용만 (`/proc/driver/nvidia`로 확인) |
| `/dev` device nodes | 생성 (udev/devtmpfs) | bind-mount로 수신 (`/proc/mounts`에 증거) |
| LXC conf/cgroup | 소유 (`/etc/pve/lxc/*.conf` — LXC 내부에서 NOT VERIFIED) | 내부에서 볼 수 없음 |
| NVIDIA userspace | UNKNOWN | 소유 (nvidia-installer, dpkg 아님) |
| X11/KDE/Sunshine/games | 없음 (LXC 내부만) | 소유 |

## 데이터 흐름

- 렌더링: Xorg(nvidia) → DP-0 → kwin_x11 compositing (세부 NOT VERIFIED) → GLX direct rendering Yes (GTX 1660 SUPER).
- 캡처: Sunshine `Screencasting with X11` (x11grab). KMS/NvFBC 사용 아님. Wayland 미사용.
- 인코딩: nvenc 실패 → vulkan 실패 → vaapi 실패 → software libx264 성공 (2026-09-13 로그 증거).
- 입력: Moonlight → Sunshine 가상 uinput (event7/8/9) → input-bridge.py가 evdev read → XTest로 :0 주입 (LXC에 udev 없어 Xorg가 직접 못 봄).
- 오디오: 앱 → PipeWire → auto_null (Dummy). 물리 싱크 없음.
- 네트워크: eth0 192.168.1.31 → Sunshine TCP 47984/47989/47990/48010. UPnP는 501 실패 반복 중.

## 왜 이렇게 구성되어 있는가 (추측이 아닌 근거)

- fake DFP-0: 물리 모니터 없이 Xorg를 띄우기 위해 `ConnectedMonitor DFP-0 + UseEDID FALSE + MetaModes` 사용. Xorg 로그에서 DFP-0 connected로 확인.
- gaming-x.service: SDDM 대신 직접 Xorg를 띄우는 custom system unit. `ExecStartPre`에서 renderD128/uinput 권한 수정 + X lock 제거.
- input-bridge.py: 파일 머리 주석에 "this LXC has no udev, so Xorg never sees Sunshine's virtual keyboard/mouse" 명시. Xorg 로그에도 "The server relies on udev..." 경고 존재.
- nvidia-vk workaround: 시스템 icd.d에 nvidia가 없어 `/home/sunshine/nvidia-vk/nvidia_icd.json`을 별도 유지. 사용처는 NOT VERIFIED.
- PRIME env: headless + NVIDIA GLX를 기본으로 강제 (`__GLX_VENDOR_LIBRARY_NAME=nvidia`).

## 다음 agent가 채워야 할 빈칸

1. 호스트: PVE 버전, 호스트 OS, `/etc/pve/lxc/<CTID>.conf` 원문 (dev/cgroup/mount), CTID 확정, privileged 확정, 호스트 NVIDIA systemd/persistenced/Toolkit 여부.
2. LXC: SDDM 역할, compositor 세부, Vulkan ICD 사용처, Sunshine 오디오 싱크 설정 원문, UDP 포트 스트림 중 동작, HEVC/AV1 실제 가능 여부 (Moonlight 실스트림 테스트 필요).
