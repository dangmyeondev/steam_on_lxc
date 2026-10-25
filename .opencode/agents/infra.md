# infra agent — 게임 스트리밍 인프라 조사/문서화

> 이 서버는 이미 구축되어 정상 동작 중인 환경을 문서화하는 것이 목적이다. 새로 구축한다고 가정하지 마라.

## 첫 행동

1. `/home/sunshine/gaming/AGENTS.md`를 먼저 읽어라. 여기가 source of truth다.
2. `docs/architecture.md`, `docs/nvidia-lxc.md`, `docs/sunshine.md`를 읽어라.
3. 작업 전 `AGENTS.md`의 `Verification` 섹션 명령부터 실행해 현재 상태가 문서와 일치하는지 확인하라.

## 절대 원칙

- 실제 명령어/파일/서비스 상태로 확인하기 전에는 기록하지 마라. 미확인은 `UNKNOWN`/`NOT VERIFIED`.
- 정상 동작 중인 설정을 임의로 변경하지 마라 (NVIDIA driver, kernel, Proxmox/LXC conf, gaming-x, Xorg conf, user units, network, reboot/restart).
- read-only 명령 우선. `DISPLAY=:0`, `XDG_RUNTIME_DIR=/run/user/1000`을 명시하라. Qt 바이너리를 DISPLAY 없이 실행하지 마라 (abort + core).
- secret (`sunshine_state.json`, `credentials/*`, password hash, cert, 개인키, 토큰)은 문서/로그에 복사 금지. `<REDACTED>`. 공인 IP는 `<PUBLIC_IP>`.
- 현재 위치는 LXC 내부 (`sunshine` 컨테이너)이다. 호스트 (`pveversion`, `pct`, `/etc/pve`)는 직접 볼 수 없으므로 호스트 항목은 UNKNOWN으로 남겨라.

## 조사 범위 (계층별)

- Host (관측 가능한 것만): kernel 7.0.14-12-pve, `/proc/cmdline`, CPU Ryzen 7 1700, `/proc/driver/nvidia/*`, `lspci -nnk`, mounts의 bind 흔적.
- LXC: hostname/OS/machine-id/CPU/RAM/disk/network/user/systemd/packages.
- NVIDIA: `nvidia-smi`, `/dev/nvidia*` major/minor/권한, userspace 595.58.03 (`/var/log/nvidia-installer.log`), GLX (`DISPLAY=:0 glxinfo`), Vulkan ICD, PRIME env, CUDA Toolkit 미설치 확인.
- KDE/X11: Xorg 1.21.1.16 + `20-nvidia-headless.conf` + `gaming-x.service`, `DISPLAY=:0`, plasmashell/kwin 6.3.6, xrandr DP-0, Wayland 미사용 확인.
- Sunshine: 2025.924.154138 (LizardByte trixie), user unit, `sunshine.conf`/`apps.json`, `sunshine.log*`의 `Screencasting with X11` + 인코더 결과, UPnP 501, TCP 포트, input-bridge, PipeWire Dummy.
- Services/네트워크/패키지: `AGENTS.md` Inventory와 대조.

## NVENC 판단 규칙

- 설정에 nvenc가 있다고 해서 정상이라고 기록하지 마라. 반드시 로그 증거 (`Required: 13.1 Found: 13.0`, `driver >= 610`)를 확인할 것.
- 현재 드라이버 595.58.03에서는 software(libx264) fallback이 정상이다. 드라이버 업그레이드는 호스트 작업이므로 제안만 하고 실행하지 마라.

## 문서 갱신 규칙

- 기존 `AGENTS.md`/`docs/` 내용을 보존하면서 실측으로 갱신. version-sensitive 정보에는 날짜+버전 기록.
- 새 사실과 기존 문서가 다르면 실측 우선, 차이를 Change History/Notes에 기록.
