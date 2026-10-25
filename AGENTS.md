# AGENTS.md — Proxmox LXC + Debian 13 + KDE/X11 + NVIDIA + Sunshine (Source of Truth)

> 조사일: 2026-09-18 (KST, UTC+9). 조사 위치: LXC 내부 (`sunshine` 컨테이너, user `sunshine`).
> 원칙: 실제 명령어/파일/서비스 상태로만 기록. 미확인 항목은 `UNKNOWN` / `NOT VERIFIED` 표기.
> 목적: 환경 변경이 아니라 reverse engineering + documentation. 정상 동작 중인 설정을 임의로 변경하지 말 것.
> Secret(비밀번호 해시, 인증서, 개인키, 토큰)은 기록하지 않고 `<REDACTED>`로 표기. 공인 IP는 `<PUBLIC_IP>`로 표기.

## Environment Overview

Proxmox 호스트의 커널(`7.0.14-12-pve`)을 공유하는 Debian 13(trixie) LXC 컨테이너(`hostname: sunshine`) 안에서,
NVIDIA GTX 1660 SUPER를 `/dev` device-node bind-mount 형태로 공유받아,
Xorg `:0` + KDE Plasma 6(X11) 데스크톱을 띄우고,
Sunshine(user systemd service)이 X11 캡처로 Moonlight 스트리밍을 제공하는 게임 스트리밍 환경이다.
핵심 검증 결과(2026-09-19): X11/NVIDIA GLX 렌더링은 정상. 드라이버 595.91.07 업그레이드 완료.
**NVENC 상태**: Sunshine 2025.924 + 드라이버 595.91.07에서 `Found H.264 encoder: h264_nvenc [nvenc]` 성공.
**Steam Big Picture**: gamescope 3.15.17 안에서 1920x1080 fullscreen 정상 렌더 확인 (2026-09-19 20:03 스크린샷).
**Steam CEF GPU 가속**: `GL_UNKNOWN_CONTEXT_RESET_KHR` → exit 8704 크래시는 GameMode LD_PRELOAD 제거 후 첫 세션에서 0건
(2026-09-19 20:03 확인). GameMode 제거가 GL-reset 크래시에도 기여했는지, 순수 드라이버 버그(#12995)인지는 NOT VERIFIED (계속 관찰).
**GameMode 사용 금지**: `gamemoderun`의 `libgamemodeauto.so.0` LD_PRELOAD가 Steam 자식 프로세스 전부를 SIGABRT시킴
(`lsof` exit 134, D-Bus abort 9000+회, steamwebhelper websocket 실패 → Steam 0x3008 다이얼로그). `moonlight-steam`에서 비활성화함.

**Moonlight virtual gamepad (SDL backend test, 2026-09-20)**: gamescope의 default wlroots/libinput path는 LXC에 udev daemon이 없어, Moonlight 연결 후 Sunshine이 동적으로 생성하는 x360 uinput gamepad hotplug를 감지하지 못하는 것으로 판단된다 (gamescope/Steam process가 `/dev/input`을 열지 않은 실측). `moonlight-steam`의 gamescope 실행에 `--backend sdl`을 명시했다. 시스템 SDL2 라이브러리에 `Container detected, disabling udev integration`, inotify 및 polling fallback 문자열이 존재함을 실측했다. 따라서 SDL backend가 Sunshine uinput hotplug를 감지할 것으로 **기대**하나, Moonlight gamepad 실사용 검증은 아직 NOT VERIFIED. gamescope + Big Picture lifecycle은 유지한다.

## Architecture

실측 기준 실제 구조:

```
Proxmox Host (NOT VERIFIED: PVE 버전/호스트 OS 직접 확인 불가, LXC 내부에서만 조사)
 └─ NVIDIA kernel driver 595.91.07 (host 소유, /proc/driver/nvidia로 컨테이너에서 확인)
     └─ LXC `sunshine` (Debian 13.7 trixie, kernel 7.0.14-16-pve 공유)
         ├─ /dev/nvidia*, /dev/dri, /dev/uinput, /dev/input bind-mount (device sharing)
         ├─ NVIDIA userspace 595.91.07 (LXC 내부, nvidia-installer --no-kernel-module)
         ├─ Xorg :0 (system unit gaming-x.service, root, nvidia driver, DFP-0 fake)
         ├─ KDE Plasma 6.3.6 + kwin_x11 (user unit plasma-x11.service, :0)
         ├─ Sunshine 2025.924.154138 (user unit sunshine.service, DISPLAY=:0, X11 capture)
         ├─ input-bridge.py (Sunshine uinput → XTest, user unit)
         ├─ PipeWire 1.4.2 (Dummy Output only)
         └─ Steam + gamescope 3.15.17 + moonlight-steam 래퍼 (`--backend sdl`, Big Picture lifecycle)
```

PCI passthrough가 아니다. GPU는 호스트 `nvidia` 드라이버에 바인딩된 채(`lspci -nnk`: `Kernel driver in use: nvidia`)
컨테이너와 공유된다. NVIDIA Container Toolkit 사용 흔적은 LXC 내부에서 발견되지 않았다(`NOT VERIFIED`: 호스트 툴킷 여부).

## Host Environment (LXC 내부에서 관측 가능한 범위만, 나머지는 UNKNOWN)

| 항목 | 실제 값 (확인 방법) |
|---|---|
| Proxmox VE 버전 | UNKNOWN (LXC 내부에 `pveversion`, `pct`, `/etc/pve` 없음) |
| Host OS (Debian 기반 버전) | UNKNOWN (컨테이너만 Debian 13 확인) |
| Kernel (공유) | `7.0.14-12-pve #1 SMP PREEMPT_DYNAMIC PMX 7.0.14-12 (2026-08-11)` (`uname -a`, `/proc/version`, `Xorg.0.log`) |
| Kernel cmdline | `BOOT_IMAGE=/vmlinuz-7.0.14-12-pve root=/dev/mapper/pve-root ro quiet pci=assign-busses apicmaintimer idle=poll reboot=cold,hard acpi_enforce_resources=lax amd_iommu=on` (`/proc/cmdline`) |
| CPU (호스트, 컨테이너에서 보임) | AMD Ryzen 7 1700 Eight-Core (`lscpu`: 16 논리 CPU 중 LXC에서 8개 online: `0,1,5,6,9,12-14`) |
| RAM (컨테이너 관점) | LXC total 12GiB, Swap 2.0GiB (2026-09-19 `free -h` 실측. 09-18 기록 8.0GiB에서 증가, 변경 주체 NOT VERIFIED). 호스트 전체 RAM은 UNKNOWN |
| GPU PCI | `0000:0a:00.0` TU116 [GeForce GTX 1660 SUPER] [10de:21c4] rev a1, MSI sub [1462:c75a] (`lspci -nnk`) |
| GPU audio/USB | `0a:00.1` TU116 HD Audio (`snd_hda_intel`), `0a:00.2` USB (`xhci_hcd`), `0a:00.3` UCSI (`nvidia-gpu`) |
| NVIDIA kernel module | `NVRM version: NVIDIA UNIX Open Kernel Module for x86_64 595.91.07 Release Build (dvs-builder@U22-I3-B08-02-2) Wed Jul 29 03:01:16 UTC 2026` (`/proc/driver/nvidia/version`). 2026-09-19 업그레이드 (이전: 595.58.03). |
| IOMMU | `amd_iommu=on` 존재. LXC device-sharing 구조이므로 IOMMU는 VM passthrough용이 아니라 호스트 부팅 옵션으로만 관측됨. 호스트 VFIO 바인딩 여부는 NOT VERIFIED |
| CTID | NOT VERIFIED (호스트 `/etc/pve/lxc/*.conf` 접근 불가). 단서: 루트 디스크가 `/dev/mapper/data-vm--3001--disk--0` (63G) → CTID 3001로 **추정만 가능**, 절대 확정 기록 금지 |
| Privileged 여부 | NOT VERIFIED (호스트 conf 미확인). 단서: `/proc/self/uid_map` = `0 0 4294967295` (unprivileged 매핑 아님), `lspci` 전체 가시, `/proc/driver/nvidia` 가시 → privileged 정황. 호스트 설정 확인 전까지 확정 금지 |
| cgroup | v2 only (`/sys/fs/cgroup` = cgroup2, `/sys/fs/cgroup/devices.list` 없음). 호스트의 `lxc.cgroup2.devices.allow` 내용은 NOT VERIFIED |
| NVIDIA systemd (host) | NOT VERIFIED (LXC 내부에서 호스트 서비스 확인 불가) |
| Host LXC conf 원문 | NOT VERIFIED. 컨테이너 내부 mount 증거로만 간접 추정 (아래 GPU Sharing 참조) |

## LXC Environment

| 항목 | 실제 값 |
|---|---|
| hostname | `sunshine` (`hostname`, `/etc/hostname`) |
| Virtualization | `lxc`, Chassis `container` (`hostnamectl`, `systemd-detect-virt`) |
| OS | Debian 13 (trixie) `DEBIAN_VERSION_FULL=13.7` (`/etc/os-release`) |
| Kernel (공유) | `7.0.14-12-pve` x86_64 |
| Machine ID | `fdf220f7ad824b19a36f8344bb4ba1c2` |
| CPU (컨테이너) | `nproc` = 8. `lscpu` 전체 16 중 online `0,1,5,6,9,12-14` |
| Memory | 12GiB + Swap 2.0GiB (2026-09-19 실측, 이전 8.0GiB에서 증가) |
| Disk `/` | 94G 중 60G 사용(67%) `/dev/mapper/data-vm--3001--disk--0` ext4 (2026-09-19 실측 — 09-18 기록 63G에서 확장됨, 확장 주체 NOT VERIFIED) |
| Network | `eth0@if143` UP MTU 1500, `192.168.1.31/24`, gw `192.168.1.1`, DNS `1.1.1.1/1.0.0.1` (Proxmox 생성 `resolv.conf`). Bridge/VLAN/방화벽 최적화는 LXC 내부에서 NOT VERIFIED |
| User | `sunshine` uid/gid 1000, groups `sunshine sudo video input render _ssh postdrop` |
| `/dev` 소유 특이점 | `/dev/input/event*` group이 `_ssh`(일반적인 `input` 아님). `/dev/nvidia*`는 `root:root 0666`. `card1`은 `root:video`, `renderD128`은 `root:postdrop` (아래 참조) |
| systemd | system running (21 units) + user@1000 running. `gaming-x.service` enabled/active, `sddm.service` disabled이나 active(아래 Services 참조) |
| Packages | 아래 Inventory 참조. `ffmpeg` 바이너리 없음(라이브러리만), `modinfo`/`iptables`/`aplay`/`qdbus`/`vdpauinfo` 없음 |

## NVIDIA GPU

- 모델: NVIDIA GeForce GTX 1660 SUPER (TU116-B), VRAM 6144MiB, VideoBIOS `90.16.48.00.2e`, PCIe 16X, Bus `0000:0a:00.0`, GPU UUID `GPU-4a2df2e6-e714-7b31-fb72-bc972d8cd0ca` (`nvidia-smi`, `/proc/driver/nvidia/gpus/0000:0a:00.0/information`).
- 드라이버: 595.58.03 (kernel + userspace 동일). `nvidia-smi` CUDA Version 표기 13.2 = 드라이버가 지원하는 CUDA API 버전이지, CUDA Toolkit 설치 의미가 아님. `nvcc` 없음, `/usr/local/cuda*` 없음 → CUDA Toolkit 미설치.
- `nvidia-smi` (2026-09-18 22:13): `P8, 34C, 16W/125W, 4057MiB/6144MiB 사용 중`이나 `No running processes found`로 표시됨 → 메모리 사용 주체와 프로세스 목록 불일치. 스트리밍/Steam/Xorg가 잡히지 않는 상태이므로 해석 주의 (Known Issues 참조).
- Device nodes (실측 `ls -l`, `stat`):
  - `/dev/nvidia0` 195,0; `/dev/nvidiactl` 195,255; `/dev/nvidia-modeset` 195,254; `/dev/nvidia-uvm` 511,0; `/dev/nvidia-uvm-tools` 511,1 (모두 `crw-rw-rw- root:root`)
  - `/dev/nvidia-caps/nvidia-cap1` 236,1, `nvidia-cap2` 236,2
  - `/dev/dri/card1` 226,1 (`root:video`), `/dev/dri/renderD128` 226,128 (`root:postdrop`), by-path `pci-0000:0a:00.0-card/render` → 동일 GPU
  - `/dev/uinput` 10,223 (`root:root 0666`)
  - `/dev/uhid` 10,239 (`root:root 0600`) → **DS5 gamepad requires root chmod 666**. `99-gaming.rules` only covers `uinput`; uhid permission must be set by `gaming-x.service` ExecStartPre (see Known Issues).
  - `/proc/driver/nvidia/params`: `DeviceFileUID 0, DeviceFileGID 0, DeviceFileMode 438(0666)` → 위 0666과 일치
- Userspace 설치 방식: LXC 내부 `/var/log/nvidia-installer.log` (2026-09-13 05:00:21): installer `595.58.03`, 옵션 `--no-kernel-module --no-dkms --no-systemd --no-backup --no-nvidia-modprobe --install-libglvnd --install-compat32-libs --no-nouveau-check -s`. 즉 호스트 커널 모듈을 재사용하고 userspace만 설치한 구조. `nvidia_drv.so`는 dpkg 소유 아님(`dpkg -S` 없음).
- 주요 userspace 파일(날짜 2026-09-13 14:00): `/usr/lib/x86_64-linux-gnu/libEGL_nvidia.so.595.58.03`, `libGLX_nvidia.so.595.58.03`, `libGLESv2_nvidia.so.595.58.03`, `/usr/lib/xorg/modules/drivers/nvidia_drv.so`, `/usr/lib/xorg/modules/extensions/libglxserver_nvidia.so`, EGL vendor `/usr/share/glvnd/egl_vendor.d/10_nvidia.json`.
- Vulkan ICD: 시스템 `/usr/share/vulkan/icd.d/`에는 nvidia 없음(gfxstream/intel/lvp/nouveau/radeon/virtio만). 대신 `/home/sunshine/nvidia-vk/nvidia_icd.json` (`library_path: /home/sunshine/nvidia-vk/libGLX_nvidia.so.595.58.03`, api 1.4.329, 심볼릭링크 모음). 어떤 서비스가 이 경로를 `VK_ICD_FILENAMES`로 쓰는지 현재 쉘/`moonlight-steam`에서는 미확인 → NOT VERIFIED (단 `moonlight-steam`은 `__VK_LAYER_NV_optimus`, `PROTON_ENABLE_NVAPI=1` 등을 export).

## GPU Sharing (Host → LXC, 실제 근거 기반 판단)

판정: **PCI passthrough가 아니라 LXC device sharing (`/dev` bind-mount) 구조.**

근거 (모두 LXC 내부 실측):

1. `lspci -nnk`에서 GPU가 호스트 드라이버(`nvidia`, `snd_hda_intel`, `xhci_hcd`)에 바인딩된 채로 컨테이너에서 보인다 → VFIO exclusive 바인딩 아님.
2. `/proc/mounts`에 호스트 udev의 devtmpfs를 그대로 바인드한 흔적:
   `udev on /dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-uvm`, `/dev/nvidia-uvm-tools`, `/dev/nvidia-caps`, `/dev/dri`, `/dev/uinput`, `/dev/input`, `/dev/nvidia-modeset`, `/dev/uhid` (모두 `devtmpfs ... mode=755`).
3. 커널 모듈은 호스트 소유(`/proc/driver/nvidia/version`만 보이고 `modinfo` 없음), LXC 내부는 userspace만 nvidia-installer로 설치.
4. NVIDIA Container Toolkit 흔적 없음(LXC 내부에 관련 패키지/데몬 미발견). 호스트 툴킷 여부는 NOT VERIFIED.

호스트 conf(`lxc.cgroup2.devices.allow: c 195:*`, `c 511:*`, `lxc.mount.entry: /dev/nvidia*` 등) 원문은 LXC 내부에서 확인할 수 없으므로 NOT VERIFIED로 기록한다. 다음 agent가 호스트 접근 권한을 얻으면 `/etc/pve/lxc/<CTID>.conf`에서 `devN`/`lxc.mount.entry`/`lxc.cgroup2.devices.allow`를 대조해야 한다.

## KDE / X11

- Xorg: `xserver-xorg-core 2:21.1.16-1.3+deb13u4`, 서버 버전 `1.21.1.16`. 실행: `/usr/lib/xorg/Xorg :0` (root, PID 2069, system unit `gaming-x.service`). 소켓 `/tmp/.X11-unix/X0` (`srwxrwxrwx root:root`).
- Xorg 설정:
  - `/etc/X11/xorg.conf.d/20-nvidia-headless.conf` (2026-09-18 20:57 적용, 주석: fake DFP-0 1920x1080 for Sunshine/Steam; 이전 설정 백업 `/root/xorg.conf.d.bak-20260918/` — 내용은 root 권한이라 미확인 NOT VERIFIED)
  - 내용 요지: `ServerLayout layout / Screen nvidia`, `Device nvidia (Driver nvidia, BusID PCI:10:0:0, AllowEmptyInitialConfiguration, ConnectedMonitor DFP-0, UseDisplayDevice DFP-0, UseEDID FALSE, ModeValidation AllowNonEdidModes, MetaModes DFP-0:1920x1080_60.00)`, Monitor Modeline `1920x1080_60.00`.
  - `/usr/share/X11/xorg.conf.d/nvidia-drm-outputclass.conf` (OutputClass nvidia → nvidia-drm).
  - `/etc/X11/xorg.conf` 없음.
- Xorg 로그 `/var/log/Xorg.0.log`: `NVIDIA dlloader X Driver 595.58.03`, `NVIDIA GLX Module 595.58.03`, `PRIME Render Offload` 지원, GPU-0 DFP-0 connected(가짜 모니터), 현재 모드 `DP-0: nvidia-auto-select @1024x768`. `(EE) systemd-logind: failed to get session: PID 2069 does not belong to any known session` 1건 존재.
- Display: `DISPLAY=:0` (gaming-x, plasma-x11, sunshine, input-bridge 모두 `:0`). SSH 세션에는 기본 DISPLAY 없음 → 명령 시 `DISPLAY=:0` 명시 필요. `XAUTHORITY` 파일 없음(`~/.Xauthority` 없음). `WAYLAND_DISPLAY` 없음, `/run/user/1000/wayland*` 없음 → Wayland 세션 아님. `kwin-wayland` 패키지는 설치되어 있으나 미사용.
- Desktop: `plasmashell 6.3.6`, `kwin 6.3.6` (`kwin_x11` 실행 중), `plasma-workspace 4:6.3.6-2`, `sddm 0.21.0+git20250502.4fe234b-2`, KF6 6.13.0, Breeze. `startplasma-x11` via `dbus-run-session` (user unit `plasma-x11.service`). `xwaylandvideobridge`도 실행 중이나 Wayland 세션 아님.
- `xrandr` (2026-09-18 심야 xrandr로 복구): `Screen 0: current 1920x1080`, `DP-0 connected primary 1920x1080 @59.96`.
  범인은 KDE kscreen 세션 복원(20:59에 1024x768 저장)이었고, 전환 후 kscreen이 1080p로 자동 저장되어 재부팅 유지 예상
  (재부팅 확인 전까지 NOT VERIFIED). `apps.json` Low Res Desktop은 당일 `HDMI-1→DP-0`, undo `1920x1200→1920x1080`
  수정 + 백업(`apps.json.bak-20260918-1080p`). Xorg conf(`20-nvidia-headless.conf`)는 무수정, `gaming-x` 재시작 없음.
- OpenGL/GLX (DISPLAY=:0 `glxinfo`): `direct rendering: Yes`, server/client GLX vendor `NVIDIA Corporation`, `OpenGL vendor NVIDIA Corporation`, `renderer NVIDIA GeForce GTX 1660 SUPER/PCIe/SSE2`, `core profile 4.6.0 NVIDIA 595.58.03`, `Dedicated video memory 6144MB / Currently available 1687MB` → GPU 가속 정상.
- PRIME env: `~/.xsessionrc`, `~/.profile`, `sunshine.service`, `moonlight-steam`에 `__GLX_VENDOR_LIBRARY_NAME=nvidia`, `__NV_PRIME_RENDER_OFFLOAD=1` 설정.
- Compositor: `kwin_x11` 실행 중이나 `qdbus` 미설치로 compositingActive 직접 조회 불가 → NOT VERIFIED (세부 상태).
- Locale 주의: `LANG=C` (UTF-8 아님) → Qt 경고 발생. `DISPLAY` 없이 `plasmashell --version`/`kwin_x11 --version` 실행 시 abort + core dump 발생 확인됨(조사 중 생성된 core는 삭제함). 앞으로는 반드시 `DISPLAY=:0`로 실행.

## Sunshine

- 버전: `2025.924.154138-1+debiantrixie` (`dpkg -l`, `sunshine --version`: commit `86188d47a7463b0f73b35de18a628353adeaa20e`, Publisher LizardByte). 설치원: `https://dl.cloudsmith.io/public/lizardbyte/stable/deb/debian trixie main` (`/etc/apt/sources.list.d/lizardbyte-stable.list`). Candidate로 `2026.914.233613`/`2026.906.222525`가 있으나 현재 설치는 2025.924로 구버전 유지 중 (이전 로그에는 2026.906.222525 실행 흔적 → 다운그레이드 정황, 변경 주체/시점 NOT VERIFIED).
- 실행 파일: `/usr/bin/sunshine`. 서비스: system unit 없음. user unit `~/.config/systemd/user/sunshine.service` (enabled/active, PID 2102, user `sunshine`, `After/Requires=plasma-x11.service`, `DISPLAY=:0`, `XDG_RUNTIME_DIR=/run/user/1000`, PRIME env, `Restart=always`).
- 설정: `~/.config/sunshine/sunshine.conf`:
  `locale=ko, upnp=disabled (2026-09-19 실측 — 09-18 기록 enabled에서 변경됨, 변경 주체 NOT VERIFIED), origin_web_ui_allowed=wan, csrf_allowed_origins=https://192.168.1.31:47990,https://<PUBLIC_IP>:47990, external_ip=<PUBLIC_IP>, system_tray=disabled, gamepad=x360, notify_pre_releases=disabled, hevc_mode=1`.
- 앱: `~/.config/sunshine/apps.json` 5개 (Desktop, Steam Gaming, Just Shapes & Beats, Overcooked! 2, PLATiNA :: LAB). Steam 게임 엔트리는 `sunshine-sync-steam-games`가 `appmanifest_*.acf`에서 자동 생성. 2026-09-20 사용자 요청으로 Low Res Desktop, Steam Big Picture, Firefox 항목 제거. `env PATH`에 `~/.local/bin` 포함.
- 인증/상태: `credentials/cacert.pem`, `cakey.pem` 존재. `sunshine_state.json`에 salt/password 해시/페어링 인증서 포함 → AGENTS에 비기록(`<REDACTED>`).
- 로그: `~/.config/sunshine/sunshine.log*` + `journalctl --user -u sunshine`. 현재 로그(2026-09-18 22:13)는 설정 echo만 있고 인코더 테스트 없음. 인코더 증거는 구 로그(`sunshine.log.2`, 2026-09-13, 당시 버전 2026.906.222525)에 존재:
  - `Screencasting with X11` → X11 캡처 경로는 동작.
  - `Trying encoder [nvenc]` → `h264_nvenc`: `Driver does not support the required nvenc API version. Required: 13.1 Found: 13.0` / `minimum required Nvidia driver ... 610.00 or newer` → `Could not open codec [h264_nvenc]` → `Encoder [nvenc] failed`.
  - `vulkan` → `Could not initialize x11 display with the given hw device type` → failed.
  - `vaapi` → `Couldn't initialize va display` → failed.
  - `software` → `libx264` 성공 (`Found H.264 encoder: libx264 [software]`).
  - 결론(구버전 2026.906): **당시 드라이버(595.58.03) + 당시 Sunshine 조합에서 NVENC/H.264 하드웨어 인코딩은 실패, software fallback.**
  - 2026-09-18 심야 (현 버전 2025.924, 로그 초기화+user 재시작 후 부팅 프로브): `Trying encoder [nvenc]` →
  `Screencasting with NvFBC` → `Creating encoder [h264_nvenc]` (13.1 에러 없음) → `Found H.264 encoder: h264_nvenc [nvenc]`
  **성공**. `av1_nvenc`는 `Codec not supported` 실패 (Turing AV1 미지원, 정상). `Couldn't release NvFBC context` 2건은
  Sunshine 자체 무시 문구와 함께 출력 → 정상 범주. `Failed to create client: Daemon not running` 1건 → NOT VERIFIED (트레이 추정).
  - 결론(갱신): **NVENC 실패는 빌드별 내장 FFmpeg의 SDK 차이(2026.906=13.1 요구)였고, 현 2025.924 + 드라이버 595.58.03에서
  H.264 NVENC 성공.** 실스트림 패킷 검증은 NOT VERIFIED (Moonlight 테스트 대기). H.265/HEVC(`hevc_mode=1` 설정)
  실사용 여부는 NOT VERIFIED.
- UPnP: `upnp=disabled` (2026-09-19 실측, conf + journal echo 일치). 이전 `enabled` 시절 journal에 `Failed to map TCP/UDP 47989/47984/47990/48010/47998/47999/48000: 501`이 약 2분 간격 반복됐었음 → WAN 스트리밍 의존 시 문제.
- 포트(실측 `ss -tulpn`, 2026-09-18): TCP `47984/47989/47990/48010` LISTEN 확인. UDP Sunshine 포트는 평시 LISTEN 미관측(스트림 중에만 열릴 가능성, 또는 권한/네임스페이스 이슈) → NOT VERIFIED. `kdeconnectd` 1716/5353 등 별도.
- Input: Sunshine 가상 `Keyboard passthrough`(event9)/`Mouse passthrough`(event7)/`Mouse passthrough (absolute)`(event8) 존재. Xorg가 udev 없이 가상 장치를 못 보므로 `sunshine-input-bridge.py`가 evdev를 읽어 XTest로 `:0`에 재주입. user unit `input-bridge.service` active. 물리 키보드 `WCH UART TO KB-MS`, `Cooler Master SR4`, Power Button, HDA 오디오 장치들도 `/dev/input`에 보임.
- Audio: PipeWire 1.4.2 + WirePlumber + pipewire-pulse active. `pactl info`: `Server PulseAudio (on PipeWire 1.4.2)`, `Default Sink: auto_null` (Dummy Output SUSPENDED). `wpctl status`: Sink `Dummy Output`만, `Default Configured Devices: Audio/Sink sink-sunshine-stereo` 표기 존재. 물리 싱크 없음 → 스트리밍 오디오는 가상 싱크 의존 구조로 보이나 Sunshine 오디오 싱크 설정 원문 대조는 NOT VERIFIED.
- Web UI: `https://192.168.1.31:47990` (+ `<PUBLIC_IP>` origin 허용). Credentials 필요. 인증서/키는 기록하지 않음.

## Networking

- LXC: `eth0@if143` (veth, host bridge의 peer로 추정되나 호스트 bridge명/VLAN은 NOT VERIFIED), `192.168.1.31/24`, GW `192.168.1.1`, MTU 1500 (특별 최적화 없음), DNS `1.1.1.1/1.0.0.1`.
- Sunshine TCP LISTEN: 47984/47989/47990/48010 (0.0.0.0). UDP는 평시 미관측 → 스트림 중 재확인 필요.
- UPnP 매핑 실패(501) 반복 → 공유기/게이트웨이 UPnP 비활성 또는 이중 NAT 가능성. LAN 내 Moonlight는 영향 없음.
- 방화벽: LXC 내부에 `iptables`/`nft` 없음. 호스트/외부 방화벽은 NOT VERIFIED.
- 민감정보: `external_ip=<PUBLIC_IP>`, pairing cert/password는 `<REDACTED>`.

## Important Configuration Files

| Path | Host/LXC | Purpose | Key content / 관계 |
|---|---|---|---|
| `/etc/X11/xorg.conf.d/20-nvidia-headless.conf` | LXC | Xorg 가짜 모니터 | DFP-0 1920x1080, BusID PCI:10:0:0. `gaming-x.service`의 Xorg가 사용 |
| `/usr/share/X11/xorg.conf.d/nvidia-drm-outputclass.conf` | LXC | nvidia-drm → nvidia 자동 매핑 | OutputClass |
| `/etc/systemd/system/gaming-x.service` | LXC(system) | Xorg :0 부팅 | `ExecStart=/usr/bin/Xorg :0`, Pre에 renderD128/uinput chmod + lock 제거, enabled |
| `/home/sunshine/.config/systemd/user/plasma-x11.service` | LXC(user) | KDE X11 세션 | `dbus-run-session -- startplasma-x11`, `After=gaming-x.service`(system 의존을 user unit에서 참조 — 대기 보장 수준은 NOT VERIFIED) |
| `/home/sunshine/.config/systemd/user/sunshine.service` | LXC(user) | Sunshine | DISPLAY=:0, PRIME env, After/Requires plasma-x11, Restart always |
| `/home/sunshine/.config/systemd/user/input-bridge.service` | LXC(user) | uinput→XTest 브릿지 | After plasma-x11+sunshine |
| `/home/sunshine/.config/sunshine/sunshine.conf` | LXC | Sunshine 설정 | 위 참조. secret 없음 |
| `/home/sunshine/.config/sunshine/apps.json` | LXC | 스트림 앱 | HDMI-1 vs DP-0 불일치 주의 |
| `/home/sunshine/.config/sunshine/sunshine_state.json` | LXC | 페어링/인증 | `<REDACTED>` — 문서에 내용 기록 금지 |
| `/home/sunshine/.local/bin/sunshine-input-bridge.py` | LXC | 입력 브릿지 | evdev→XTest, LXC no-udev workaround |
| `/home/sunshine/.local/bin/moonlight-steam` | LXC | Steam Gaming / 개별 게임 래퍼 | `--app-id <steamid>` 지원. gamepad 대기 Zenity + gamescope(SDL backend) + Steam `steam://rungameid/` |
| `/home/sunshine/.local/bin/sunshine-sync-steam-games` | LXC | Steam Library 동기화 | `appmanifest_*.acf`에서 설치 게임 자동 등록, 스트림 중에는 Sunshine restart 미룸 |
| `/home/sunshine/.config/systemd/user/sunshine-steam-sync.service` | LXC(user) | Steam-Sunshine 동기화 | one-shot, safe-restart 포함 (스트림 중이면 restart 미룸) |
| `/home/sunshine/.config/systemd/user/sunshine-steam-sync.timer` | LXC(user) | 동기화 주기 실행 | 부팅 2분 후, 이후 1시간마다 |
| `/home/sunshine/.xsessionrc`, `~/.profile`, `~/.bashrc` | LXC | PRIME env | `__GLX_VENDOR_LIBRARY_NAME=nvidia`, `__NV_PRIME_RENDER_OFFLOAD=1` |
| `/etc/udev/rules.d/99-gaming.rules` | LXC | 권한 | `renderD128 MODE=0666`, `uinput MODE=0666` |
| `/home/sunshine/nvidia-vk/nvidia_icd.json` | LXC | Vulkan ICD workaround | 시스템 icd.d에 nvidia 없음. 사용처 NOT VERIFIED |
| `/var/log/Xorg.0.log` | LXC | Xorg 증거 | driver 595.58.03, DFP-0, 1024x768 |
| `/var/log/nvidia-installer.log` | LXC | userspace 설치 증거 | 595.58.03 --no-kernel-module 등 |
| `/etc/pve/lxc/<CTID>.conf` | HOST | LXC GPU/cgroup/mount 원문 | **NOT VERIFIED** — 호스트 접근 시 최우선 확인 |
| `/root/xorg.conf.d.bak-20260918/` | LXC | 이전 Xorg 백업 | root 권한으로 미확인 NOT VERIFIED |

## Services (부팅 → 스트리밍 도달 경로)

실측 active units 기준:

1. System: `gaming-x.service` (enabled, Active since 20:58, `/usr/bin/Xorg :0`) → Xorg :0 선행.
2. System: `sddm.service` (disabled이나 active since 20:57, PID 2028). Xorg :0의 주인이 gaming-x이므로 SDDM의 역할(로그인 관리 vs 잔류 프로세스)은 LXC 내부 로그만으로 확정 불가 → NOT VERIFIED. 끄거나 건드리지 말 것.
3. `user@1000.service` → user units:
   - `pipewire/pipewire-pulse/wireplumber` (20:31~)
   - `input-bridge.service` (20:31~, Restart always)
   - `plasma-x11.service` (20:59~, dbus-run-session→startplasma-x11→kwin_x11/plasmashell)
   - `sunshine.service` (20:59~, Requires plasma-x11, Restart always)
4. Moonlight Steam Gaming 연결 시 `moonlight-steam` → gamescope (`--backend sdl`, `-W 1920 -H 1080 -f -e`) → Steam Big Picture. Moonlight Desktop 선택 시 gamescope/Big Picture는 실행하지 않고 KDE X11 desktop으로 연결.

재부팅 후 도달 순서로 추정: `multi-user.target → gaming-x(Xorg :0) → user@1000 → pipewire → plasma-x11(KDE :0) → sunshine → input-bridge`. SDDM 개입 지점은 NOT VERIFIED이므로 부팅 순서 변경 금지.

주요 override: `/etc/systemd/system/gaming-x.service`와 `~/.config/systemd/user/*` 3종 (`sunshine`, `plasma-x11`, `input-bridge`).

## Package / Version Inventory (2026-09-18, LXC)

| Package | Version | Source |
|---|---|---|
| NVIDIA userspace (installer) | 595.58.03 | nvidia-installer (.run, dpkg 아님), `/var/log/nvidia-installer.log` |
| NVIDIA kernel module (host) | 595.58.03 | `/proc/driver/nvidia/version` |
| sunshine | 2025.924.154138-1+debiantrixie | LizardByte stable (trixie). candidate 2026.914 존재하나 미설치 |
| xserver-xorg-core | 2:21.1.16-1.3+deb13u4 | Debian trixie |
| xserver-xorg-video-dummy | 1:0.4.0-1 | Debian (설치됨, 현재 사용 여부는 NOT VERIFIED — 실제 driver는 nvidia) |
| sddm | 0.21.0+git20250502.4fe234b-2 | Debian |
| plasma-workspace | 4:6.3.6-2 | Debian (plasmashell 6.3.6) |
| kwin-x11 / kwin-wayland / kwin-common | 4:6.3.6-1 | Debian (wayland는 미사용) |
| kde-plasma-desktop | 5:162 | Debian |
| KF6 libs | 6.13.0-* | Debian |
| PipeWire | 1.4.2-1 | Debian (libpipewire-0.3-0t64) |
| PulseAudio client | 17.0+dfsg1-2+b1 | Debian |
| Mesa (GL/Vulkan) | 25.0.7-2+deb13u1 | Debian (libgl1-mesa-dri, libEGL_mesa, mesa-vulkan-drivers) |
| libglvnd | 1.7.0-1+b2 | Debian |
| Vulkan loader | 1.4.309.0-1 | Debian |
| libva | 2.22.0-3 | Debian |
| libvdpau1 | 1.5-3+b1 | Debian |
| libevdev2 / python3-evdev | 1.13.4+dfsg-1 / 1.9.1-1 | Debian (input-bridge 의존) |
| steam-installer/steam-libs | 1:1.0.0.83~ds-3 | Debian + Valve Steam runtime (`~/.steam/debian-installation`) |
| gamescope | 3.15.17 (`/usr/local/bin/gamescope`) | Debian 패키지 아님 (빌드/수동 설치로 추정, 출처 NOT VERIFIED) |
| gamemode/gamemode-daemon/libgamemodeauto0 | 1.8.2-2 (amd64+i386) | Debian. **Steam 실행에 사용 금지** (Known Issues 10 참조). 데몬은 유지, `moonlight-steam`에서만 비활성 |
| firefox-esr | 140.15.0esr-1~deb13u1 | Debian |
| libavcodec61 (ffmpeg libs) | 7:7.1.5-0+deb13u1 | Debian. `ffmpeg` 바이너리 없음 |
| kernel (공유) | 7.0.14-12-pve | Proxmox host |

## Verification (정상 확인 명령과 기대 결과)

SSH에서는 DISPLAY/XDG를 매번 명시해야 한다:

```bash
# 1. 컨테이너/커널
hostnamectl; uname -a  # sunshine, Debian 13, 7.0.14-12-pve, Virtualization: lxc
# 2. GPU kernel + userspace 일치
cat /proc/driver/nvidia/version  # 595.58.03
nvidia-smi  # GTX 1660 SUPER, Driver 595.58.03, CUDA 13.2
ls -l /dev/nvidia* /dev/dri  # 195/*, 511/*, 226/* 존재
# 3. X11
ls -l /tmp/.X11-unix/X0
DISPLAY=:0 xrandr  # DP-0 (현재 1024x768, 1920x1080 가능)
DISPLAY=:0 glxinfo | grep -E "direct rendering|OpenGL (vendor|renderer|.*version)"  # Yes / NVIDIA / GTX 1660 SUPER / 4.6.0 NVIDIA 595.58.03
head -n 30 /var/log/Xorg.0.log  # 1.21.1.16, nvidia 595.58.03
# 4. KDE
DISPLAY=:0 plasmashell --version  # 6.3.6 (DISPLAY 없이 실행하면 abort하므로 반드시 지정)
ps aux | grep -E "kwin_x11|plasmashell|startplasma-x11" | grep -v grep
# 5. Sunshine
XDG_RUNTIME_DIR=/run/user/1000 systemctl --user status sunshine plasma-x11 input-bridge
ss -tlnp | grep -E "47984|47989|47990|48010"  # TCP LISTEN
cat ~/.config/sunshine/sunshine.conf
grep -i -E "nvenc|libx264|vaapi|vulkan|Screencasting with X11" ~/.config/sunshine/sunshine.log*
# 6. Input/audio
ls -l /dev/uinput /dev/input/event* | head
python3 -c "import evdev"  # input-bridge 의존성
DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/1000 pactl info  # PipeWire 1.4.2, Default Sink auto_null
DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/1000 wpctl status
```

## Troubleshooting (우선순위 순)

1. Host NVIDIA: 호스트 접근 가능 시 `nvidia-smi`, `/dev/nvidia*` major/minor, 커널 모듈 버전. LXC 내부에서는 `/proc/driver/nvidia/version` + `nvidia-smi`로 대리 확인.
2. LXC device 가시성: `/dev/nvidia0,nvidiactl,nvidia-modeset,nvidia-uvm,nvidia-uvm-tools`, `/dev/dri/card1,renderD128`, `/dev/uinput`, `/proc/mounts`의 bind 흔적. 없으면 호스트 conf 문제 → 호스트에서 `/etc/pve/lxc/<CTID>.conf` 확인.
3. Userspace 일치: LXC userspace(595.91.07)와 host kernel(595.91.07) 버전 일치 여부. 불일치 시 GLX/Vulkan 깨짐. `/var/log/nvidia-installer.log` 대조.
4. Xorg: `systemctl status gaming-x`, `/var/log/Xorg.0.log`(EE), `/etc/X11/xorg.conf.d/20-nvidia-headless.conf`, `DISPLAY=:0 xrandr/glxinfo`.
5. KDE: `systemctl --user status plasma-x11`, `kwin_x11`/`plasmashell` 프로세스, `journalctl --user -u plasma-x11`. DISPLAY 없이 Qt 바이너리 실행 금지.
6. Sunshine service: `systemctl --user status sunshine`, `sunshine.conf`, `journalctl --user -u sunshine`(UPnP 501 반복은 기지 현상).
7. Display capture: 로그에 `Screencasting with X11` 있는지. `WAYLAND_DISPLAY`가 비어 있어야 정상(X11 모드).
8. NVENC: `sunshine.log*`에서 `Required: 13.1 Found: 13.0` / `minimum required ... 610.00` 패턴 검색. 현재 드라이버 595.91.07 + Sunshine 2025.924에서는 `h264_nvenc` 성공 확인됨. 드라이버 업그레이드는 호스트 작업이므로 LXC에서 시도 금지.
9. Input: Sunshine 가상 장치(event7/8/9) 존재 + `input-bridge.service` active. 없으면 `python3-evdev`, XTest(`libxtst`) 확인.
10. Audio: `pactl info` Sink가 `auto_null`인지. 물리 싱크를 기대하지 말 것.
11. Network: `ss -tlnp`(TCP 4포트), Moonlight 페어링은 `sunshine_state.json`이 아닌 Web UI로. UPnP 501은 LAN 사용 시 무시 가능.
12. Steam 0x3008/BPM 미진입: ① `~/.steam/steam/logs/console_log.txt`에서 `Failed to connect to websocket` 확인 →
    ② `GetIPCConnectionDetails ... command failed: 134` 있으면 LD_PRELOAD 오염 의심 → ③ 재현 테스트
    `LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libgamemodeauto.so.0 /usr/bin/lsof -P -F upnR -i TCP@127.0.0.1:47990`
    (exit 134 + dbus assertion이면 GameMode 범인 확정) → ④ `moonlight-steam`의 GAMERUN이 비활성인지 확인.
    `LD_PRELOAD`가 있는 채로 Steam을 실행하지 말 것.

## Known Constraints (함부로 변경 금지)

- 호스트 NVIDIA 드라이버/커널/Proxmox/LXC conf 재생성/reboot/service restart — 본 작업 범위 외. 특히 드라이버 595→610+ 업그레이드는 NVENC 해결책처럼 보여도 호스트 전체 작업이므로 단독 결정 금지.
- `gaming-x.service`, Xorg conf, user units 3종(sunshine/plasma-x11/input-bridge), `99-gaming.rules`, PRIME env — 동작 중인 경로이므로 수정 전 백업 + 로그 대조 필수.
- Sunshine 업그레이드(2025.924 → 2026.x): 구 로그(2026.906)에서도 동일 NVENC 실패가 나므로 업그레이드가 NVENC 해결책이 아님. 업그레이드 시 설정/페어링 영향 검토 필요.
- `apps.json`의 HDMI-1, xrandr 해상도(1024x768 vs 1920x1080) 변경은 스트림 해상도에 직접 영향 → Moonlight 테스트 없이 변경 금지.
- Secret 파일(`sunshine_state.json`, `credentials/*`) 열람 최소화, 문서/로그에 복사 금지.

## Known Issues (실측 기반, 2026-09-18)

1. **NVENC 빌드별 상이 (2026-09-18 갱신)**: 2026.906은 `Required 13.1 / Found 13.0`, `driver >= 610 required`로 실패 →
  `libx264` fallback. 현 2025.924는 부팅 프로브에서 `h264_nvenc` 성공 (드라이버 595.58.03 그대로). 실스트림 검증 대기.
  AV1 실패는 Turing 정상. `nvidia-smi` 메모리 4057MiB 사용 vs 프로세스 없음 표기는 미해결 관측 유지.
2. **UPnP 매핑 실패 반복**: `Failed to map ... : 501` 2분 간격. WAN 경유 시 포트포워딩 수동 필요 가능성.
3. **해상도/출력명 불일치 (2026-09-18 해소)**: 원인은 kscreen 세션 복원. `xrandr`로 DP-0 1920x1080 복구 + kscreen 자동 저장,
  `apps.json` Low Res Desktop `HDMI-1→DP-0` + undo 모드 수정 완료. Xorg conf 무수정, `gaming-x` 재시작 없음. 재부팅 유지 여부는 NOT VERIFIED.
4. **SDDM 역할 불명**: disabled이나 active. gaming-x와 관계 NOT VERIFIED.
5. **Vulkan ICD 비표준 경로**: 시스템 icd.d에 nvidia 없음, `/home/sunshine/nvidia-vk` workaround. 사용처 NOT VERIFIED.
6. **Locale C**: Qt UTF-8 경고. `plasmashell --version`을 DISPLAY 없이 실행하면 abort + core (조사 중 2회 발생, 삭제 완료).
7. **오디오 Dummy only**: `auto_null`만 존재. 물리 출력 기대 금지.
8. **게임패드(xinput) 미검증 (2026-09-18)**: `input-bridge.py`는 키보드/마우스 전용(XTest). 가상 x360 패드는 패드 달린
  클라이언트 접속 시 Sunshine이 uinput으로 생성하는 구조라 평시 부재가 정상. LXC(udev 없음) 환경에서 게임의 패드 인식
  여부는 Moonlight 테스트 대기.
9. **게임패드 미동작 (2026-09-20, SDL backend 적용·실사용 검증 대기)**: Moonlight에서 가상 Xbox 360 게임패드가 Steam/BPM에서 인식되지 않음.
  근본 원인으로 판단: `gamepad=x360`일 때 Sunshine은 `/dev/uinput`에 Xbox One pad를 Moonlight client 연결 후 동적으로 생성한다.
  gamescope의 default wlroots/libinput path는 libudev hotplug에 의존하지만 LXC 내부에는 `systemd-udevd` daemon이 없어서 새 `eventN`
  장치를 감지하지 못한다. 실제로 default gamescope와 Steam process 모두 `/dev/input` 장치를 열지 않은 것을 확인했다.
  **추가 실측 (09:09 연결 세션)**: Sunshine은 `Gamepad 0 will be Xbox One controller (default)`를 로그에 남기고,
  `/dev/input/js2` = `Sunshine X-Box One (virtual) pad`를 생성했다. 그러나 gamescope/Steam 어느 프로세스도 해당 node를 열지 않았다.
  이유는 gamepad가 gamescope 시작 뒤에 생성되기 때문이다. **조치**: `moonlight-steam`의 gamescope 명령에 `--backend sdl`을 명시하고,
  gamescope 실행 전에 최대 60초 동안 Sunshine virtual pad가 생성될 때까지 대기하도록 변경했다. 실측 세션에서 gamepad 생성은
  앱 시작 약 47초 뒤여서 짧은 대기는 controller 초기화와 경쟁한다. 대기 중 Moonlight stream에는 Zenity countdown 화면이 표시되며,
  controller button 입력을 안내한다. 이로써 gamescope가 시작 시점부터 `/dev/input/jsN` 장치를 열 수 있다. 시스템 SDL2에는
  `Container detected, disabling udev integration`, inotify 및 polling fallback 코드 문자열이 존재한다. 수정 후 새 Moonlight
  Steam Gaming 세션에서의 실사용 검증은 아직 NOT VERIFIED.
  **DS5 주의**: `/dev/uhid`가 `root:root 0600`이라 Sunshine user는 접근 불가. `gamepad=x360`이면 영향 없으나
  `gamepad=ds5` 수동 선택 시 root 권한으로 `/dev/uhid`에 `chmod 666` 또는 `gaming-x.service` ExecStartPre에 추가해야 함
  (현재 root 접근 불가 → 사용자 작업).
9. **재생 중 오디오 클리핑 제보 (2026-09-18)**: 유휴 싱크(`auto_null` 100%/0dB, SUSPENDED) 클린, pipewire 3종 active,
  최근 30분 xrun 0건. 재생 중 `pactl list sink-inputs` + xrun 재확인 대기.
10. **Steam 0x3008 다이얼로그 → 세션 종료 (2026-09-19, 원인 확정·해결)**: `moonlight-steam` cold-start(Big Picture)
  후 스트림은 `h264_nvenc` 정상 시작하나, Steam이 `steamwebhelper` websocket 연결 실패
  (`webuitransportcontroller.cpp:175 Failed to connect to websocket`)를 감지하고 0x3008 fatal-error 다이얼로그
  (700x350, `Steam 다시 시작/steamwebhelper 다시 시작/계속 진행/종료` 선택지)를 띄워 BPM으로 진입하지 못함.
  구 로그의 SIGSEGV (`steam.sh: line 1011 Segmentation fault`)는 동일 websocket 실패의 이전 귀결(CEF 플래그 적용 전).
  **근본 원인 = `gamemoderun`의 `libgamemodeauto.so.0` LD_PRELOAD** (아래 연쇄 전부 설명):
  LD_PRELOAD된 모든 Steam 자식에서 `dbus_pending_call_block` assertion → SIGABRT (exit 134).
  증거(2026-09-19 재현): `LD_PRELOAD=.../libgamemodeauto.so.0 /usr/bin/lsof ...` → 동일 assertion + `Aborted` + exit 134.
  연쇄: `lsof` 134 (`GetIPCConnectionDetails` 실패) → IPC endpoint 미확인 → websocket 미연결 → 0x3008 다이얼로그
  (+ D-Bus abort 9000+회, CEF GPU exit 8704 15회도 동일 세션에서 관측 — GameMode 기여 여부는 NOT VERIFIED).
  **조치**: `moonlight-steam`에서 `gamemoderun` 비활성화 + `unset LD_PRELOAD`. 이후 첫 세션에서 D-Bus abort 0건,
  `lsof` 성공, websocket 연결, BPM 1920x1080 정상 렌더(스크린샷) 확인. 구 기록의 "dbus abort는 치명적이지 않음"은
  정정함 — 치명적이었음. `~/.cache/gamescope-probe` 캐시 방식은 폐지하고 binary+ICD 존재 확인(`check_gamescope`)으로 교체.
  재발 시 `moonlight-steam`의 GAMERUN 주석 해제 금지 (upstream 수정 전까지).
11. **좌상단 흰색 직사각형 아티팩트 (2026-09-19)**: `xwaylandvideobridge` 윈도우(174x174 @ -99+0, mapped,
  `_NET_WM_WINDOW_OPACITY=0`)가 solid white로 페인트됨. `kwinrc [Compositing] Enabled=false`라 opacity 무시 +
  화면 밖(-99) 트릭이 75px만큼 누출 → 좌상단 흰 띠. Wayland 세션 자체가 없으므로 해당 브릿지는 무용지물.
  수정은 미적용 (autostart 비활성화/kwin 룰 등 사용자 승인 대기). 증거: `xwd -id 0x2a00008` 100% white,
  root 스크린샷 2회 byte-identical (정지 화면).
12. **Steam CEF GPU 가속 미작동 (2026-09-19)**: NVIDIA 드라이버 595.58.03→595.91.07 업그레이드 후에도 CEF GPU 프로세스가
   `GL_UNKNOWN_CONTEXT_RESET_KHR` → exit 8704로 3회 크래시 후 software 폴백. 모든 CEF 플래그(`--use-angle=gl`,
   `--disable-gpu-sandbox`, `-cef-in-process-gpu`, `--use-gl=desktop` 등)와 모든 백엔드(ANGLE GL, Vulkan, swiftshader,
   native GLX)에서 동일. GPU 프로세스는 초기화 성공(`gpu_compositing: enabled`) 후 수 초 만에 컨텍스트 리셋.
   LXC 컨테이너 환경에서 NVIDIA 드라이버가 CEF의 GL 컨텍스트를 안정적으로 유지하지 못하는 것이 근본 원인.
   스트리밍/Sunshine/NVENC에는 영향 없음 (X11 캡처는 별도 경로). Steam Big Picture는 software rendering으로 동작.
   **DRM modeset 상태**: 호스트에서 `nvidia_drm.modeset=Y` 확인됨 (이미 활성화). modeset 미활성화가 원인은 아님.
   **A/B 테스트 불필요 확정**: GitHub issue #12995에서 정확히 동일 문제가 보고됨 (NVIDIA 580+/590+/595+, EGL/GLX/Vulkan 모든 백엔드).
   LXC 전용 문제가 아닌, NVIDIA 드라이버 + Chromium CEF Chrome 126의 알려진 호환성 버그.
   EGL PBuffer 컨텍스트는 정상 작동 확인 (Python 테스트). X11 window surface에서만 크래시 발생.
   **추가 관측 (2026-09-19 20:03)**: GameMode LD_PRELOAD 제거 + gamescope + `--use-angle=gl --disable-gpu-sandbox`
   조합의 첫 세션에서는 exit 8704이 0건이었음 (BPM 1920x1080 정상 렌더). 종전 15회 크래시는 GameMode가 활성화된
   세션에서만 관측됨. GameMode가 GL-reset 크래시에 기여했는지, 우연(드라이버 버그의 간헐성)인지는 NOT VERIFIED —
   CEF 크래시가 재발해도 Known Issue 10의 연쇄(websocket 실패→0x3008)와 혼동하지 말 것. 계속 관찰.

## Recovery / Rollback

- Xorg: `/etc/X11/xorg.conf.d/20-nvidia-headless.conf` 수정 전 복사. 백업 후보 `/root/xorg.conf.d.bak-20260918/` 존재(내용 미확인). 복구: `systemctl status gaming-x` + `/var/log/Xorg.0.log` 대조 후 `systemctl restart gaming-x`는 최후 수단(현재 세션 전부 영향).
- User units: `~/.config/systemd/user/{sunshine,plasma-x11,input-bridge}.service` + `~/.config/sunshine/sunshine.conf,apps.json`을 백업 후 수정. `systemctl --user daemon-reload` 필요.
- NVIDIA userspace: 재설치는 `/var/log/nvidia-installer.log`의 동일 버전/동일 옵션으로만. 커널 모듈 옵션 절대 사용 금지(`--no-kernel-module` 필수).
- Sunshine: 설정 변경 후 `systemctl --user restart sunshine`, `journalctl --user -u sunshine -f`로 확인. 페어링 초기화 시 Moonlight 재페어링 필요.
- 최우선 복구 원칙: 호스트 conf를 모르므로 LXC 내부 파일부터 복구하고, 호스트 작업은 PVE 접근 확보 후 별도 승인 하에 수행.

## Change History

- 2026-09-18 심야: NVENC 상태 정정(2025.924 부팅 프로브 `h264_nvenc` 성공, 13.1 실패는 2026.906 한정) + 캡처 경로 NvFBC 기록 +
  해상도 1080p 복구(kscreen 범인 확정, `apps.json` DP-0 수정+백업) + 게임패드/오디오클리핑 미검증 항목 추가. 변경: `apps.json` 2줄,
  `sunshine.log*` 초기화 후 sunshine user service 재시작 1회. Xorg conf/`gaming-x`/호스트 무수정. Sunshine 설정 백업
  `~/backup-sunshine-20260918/` (conf/apps/state/service) + 구 로그 동봉.
- 2026-09-19 오전: Moonlight Steam 미실행 해결. 원인 = 32-bit NVIDIA userspace(`/usr/lib32`, 595.58.03)가 ld.so.conf에 없어
  32-bit Steam이 nouveau로 폴백 → `glx: failed to create dri3 screen` → steamwebhelper 미생성 → Big Picture 미오픈.
  구 silent Steam(09-18 20:59~)이 URL 요청을 9시간 무시한 것도 동일 원인. 조치: Steam 재시작 + `LD_LIBRARY_PATH=/usr/lib32`
  영속화(`moonlight-steam`, `steam-silent.desktop`, `~/.profile`, `~/.xsessionrc`, 백업 동일 폴더) → webhelper 생성 +
  NVIDIA 로드 + `:0` 윈도우 확인. 이후 시스템 전역 수정도 완료(`/etc/ld.so.conf.d/nvidia-compat32.conf`에 `/usr/lib32`,
  `ldconfig` 캐시에 32/64-bit `libGLX_nvidia` 동시 확인) → user-level export는 이중 안전장치로 유지.
- 2026-09-19 오전: WAN 포트포워딩 (OpenWrt, WAN 공인 IP 확인, 이중NAT 없음). 기존 UPnP 잔재(TCP 47984-47989,
  UDP 47998-48010/48100-48110) + 수동 추가(TCP 47990/48010) → Sunshine 전 포트 WAN 도달. fw4는 src_dport 공백
  리스트 미지원 → 단일 포트 규칙으로만 추가. UPnP 501 반복은 잔존하나 수동 규칙으로 무력화.
- 2026-09-19 오전: Xorg 포함 재시작 (gaming-x → plasma-x11 → input-bridge → sunshine 순). kscreen이 1080p 그대로
  복원, Sunshine `h264_nvenc` 재확인, TCP 4포트 LISTEN. Steam은 Moonlight cold-start 운용으로 전환되어 상주 없음.
- 2026-09-19 오후: Steam 세그폴트 2회(14:29대, 14:52:45) → Moonlight 0x3008 2건 + 좌상단 흰 아티팩트 원인 확정
  (xwaylandvideobridge white 75px 누출, compositing off). 실측만 반영, 시스템 변경 없음(read-only 진단 + 스크린샷은
  `/tmp/opencode/`에만 저장). 부수 관측: 루트 디스크 63G→94G 확장, `sunshine.conf` upnp=disabled, gamescope-probe=FAIL.
- 2026-09-19 오후(사용자 승인, Both fixes): (a) 흰 아티팩트 제거 — `~/.config/autostart/org.kde.xwaylandvideobridge.desktop`
  (`Hidden=true` override, 재활성화는 파일 삭제로 복원) + 실행 중 프로세스(PID 636) 종료. 스크린샷으로 좌상단 정상
  (wallpaper) 확인. (b) Steam 안정성 테스트 — moonlight-steam과 동일 env/flag로 `-bigpicture` cold-start →
  2.5분+ 안정, Big Picture GPU 렌더 정상(스크린샷), 덤프 0건. 이전 크래시(~60초 내 SIGSEGV)는 재현 안 됨(단발성/
  조건부로 판단, 계속 관찰). 테스트 후 Steam 정상 종료시켜 원래 상태(미실행)로 복원. sunshine/plasma/input-bridge
  무수정, 1080p/TCP 4포트 정상.
- 2026-09-19 오후: NVIDIA 드라이버 업그레이드 595.58.03→595.91.07 (호스트 + LXC userspace). 호스트에서 커널 모듈 설치,
  LXC에서 nvidia-installer `--no-kernel-module`로 userspace 갱신. nvidia-xconfig가 생성한 `/etc/X11/xorg.conf` 삭제
  (`20-nvidia-headless.conf`와 충돌). nvidia-vk 심볼릭링크 595.91.07 갱신. 32-bit 라이브러리 경로 `/usr/lib32`→
  `/usr/lib/i386-linux-gnu` (Debian multiarch)로 변경, `LD_LIBRARY_PATH`/`ld.so.conf` 업데이트.
  gaming-x/plasma-x11/input-bridge/sunshine 재시작. OpenGL 4.6.0 NVIDIA 595.91.07 확인, NVENC h264 확인.
  **Steam CEF GPU 가속 테스트 결과**: 드라이버 업그레이드에도 `GL_UNKNOWN_CONTEXT_RESET_KHR` 크래시 지속.
  모든 CEF 플래그/백엔드 테스트 (ANGLE GL/Vulkan, swiftshader, native GLX, -cef-in-process-gpu,
  --disable-gpu-driver-bug-workarounds 등)에서 동일. GPU 프로세스 초기화 성공 후 수 초 만에 컨텍스트 리셋.
  근본 원인: LXC 컨테이너 환경에서 NVIDIA 드라이버의 GL 컨텍스트 안정성 한계 (드라이버 버전 무관).
  스트리밍/Sunshine/NVENC에는 영향 없음. Steam Big Picture는 software rendering으로 동작.
- 2026-09-20: Sunshine Library에서 사용자 요청으로 Low Res Desktop, Steam Big Picture, Firefox를 제거. 이후 `sunshine-sync-steam-games`
  Python 스크립트와 `sunshine-steam-sync.timer`를 추가해 `~/.steam/debian-installation/steamapps/appmanifest_*.acf`를 주기적으로 읽고
  설치된 Steam 게임을 Sunshine Library에 자동 등록. 부팅 2분 후, 이후 1시간마다 실행. 스트리밍 중이거나 gamescope가 실행 중이면
  `~/.local/state/sunshine-steam-sync/pending-sunshine-restart` marker를 두고 다음 실행 시 안전하게 restart.   동기화 스크립트는
  `~/.steam/debian-installation/appcache/librarycache/<appid>`에서 Steam library cache 이미지(우선순위: `library_600x900.jpg`,
  `library_capsule.jpg`, `header.jpg`, `library_header.jpg`)를 `~/.config/sunshine/assets/`로 복사한다. Sunshine의 `/appasset`
  엔드포인트는 **PNG 파일만** 서빙하며(소스 코드 `validate_app_image_path` 확인), JPEG는 자동으로 기본 box 이미지로 대체되므로
  스크립트는 `convert`/`ffmpeg`로 JPEG를 **PNG로 변환** 후 `image-path`에 `steam_<appid>.png` 형태로 기록. 현재 등록된 게임:
  Just Shapes & Beats (531510), Overcooked! 2 (728880), PLATiNA :: LAB (3430470).
  `moonlight-steam`은 이제 `--app-id <steamid>` 인수를 받아 개별 게임도 gamescope(SDL backend) + virtual gamepad 대기 경로로 실행.
- 2026-09-20: Steam silent-background 설계는 사용자 요구(gamescope에서 Big Picture, Desktop 선택 시 gamescope+Big Picture 종료)와 맞지 않아 제거.
  Moonlight virtual gamepad의 원인은 gamescope default wlroots/libinput이 udev daemon 없는 LXC에서 연결 뒤 동적으로 생성되는
  Sunshine uinput gamepad를 hotplug로 감지하지 못하는 것으로 판단 (실측: default gamescope/Steam 모두 `/dev/input` 미열기).
  **조치**: `moonlight-steam`의 gamescope 실행에 `--backend sdl` 명시. 시스템 SDL2에서 container detection으로 udev integration을
  끄고 inotify/polling fallback을 제공하는 문자열을 확인. 추가로 gamescope 실행 전 최대 12초간 `Sunshine X-Box One (virtual) pad`
  생성 대기 로직을 넣었다. 연결 세션에서 생성된 `/dev/input/js2`를 gamescope/Steam이 열지 않은 실측상, 이 순서 보장이 필요하다.
  SDL backend gamepad 실사용 검증은 NOT VERIFIED. `steam-background.service` 삭제·disable, `sunshine.service`의 steam-background
  의존성 제거. 최종 경로는 Moonlight Steam Gaming → gamescope SDL backend → Big Picture, 세션 종료 → gamescope/Big Picture 종료
  → Desktop은 KDE X11 그대로이다.
- 2026-09-19 저녁: Steam 0x3008 근본 원인 확정·해결 = `gamemoderun` LD_PRELOAD (`libgamemodeauto.so.0`)가
  Steam 자식 전부 SIGABRT (재현: LD_PRELOAD+lsof → dbus assertion + exit 134). 연쇄: lsof 134 → websocket 실패 →
  0x3008 다이얼로그. 조치: `moonlight-steam`에서 gamemoderun 비활성화 + `unset LD_PRELOAD` + `~/.cache/gamescope-probe`
  캐시 폐지(binary+ICD check로 교체) + gamescope 경로에 CEF GLX 플래그 + D-Bus/XDG env 전달. 검증: D-Bus abort 0건,
  lsof 성공, websocket 연결, gamescope 내 BPM 1920x1080 정상 렌더(20:03 스크린샷), CEF exit 8704 0건. 테스트 후
  `steam -shutdown`으로 graceful 종료 (IPC 복구 증거) → 원래 상태(미실행) 복원. 부수 관측: `free` total 12GiB
  (09-18 기록 8.0GiB에서 증가, 변경 주체 NOT VERIFIED), gamescope 실측 버전 3.15.17 (기존 3.16.28 기록 정정).
  `/tmp`의 kill -9 잔재 30+개(steam*/.com.valvesoftware.Steam.*/steam_chrome_shmem*) 청소 — 원인과 무관했음.
- 2026-09-18: 본 문서 초판 (LXC 내부 read-only 조사 기반). 기존 AGENTS.md 없음 → 신규 작성. 시스템 변경 없음. 단 조사 과정에서 `plasmashell --version` DISPLAY 미지정 실행으로 core 2개 생성 → 삭제 완료. 그 외 파일 생성/수정 없음(본 문서 제외).
- 과거 흔적(로그/파일 날짜 기반, 행위자 NOT VERIFIED): 2026-09-13 NVIDIA userspace 595.58.03 설치, Sunshine 2026.906 실행 후 현재 2025.924로 변경, 2026-09-18 Xorg headless conf 적용 + PRIME env 추가 + input-bridge/sunshine/plasma user units 구성.
- 2026-10-16 (full stack restart): user 요청. 순서: user units stop (sunshine/input-bridge/plasma-x11) → pipewire 3종 restart → `gaming-x` + `chrome-remote-desktop@sunshine` restart (Xorg :0/:20 fresh) → plasma-x11 → input-bridge → sunshine. 구 :20 plasmashell 좀비 1개 잔류 → kill. :0/:20 모두 스크린샷 정상 (wallpaper+panel, dialog 없음). Sunshine nvenc probe 정상, DP-0 1920x1080 유지.
- 2026-10-16 (CRD PIN 거부 원인 확정·해결): 증상=클라이언트에 "PIN incorrect". 실체는 2단 인증의 2단계 실패. (1) 10-15 5회 시도는 SPAKE2 PIN 통과 후 `pam_acct_mgmt(chrome-remote-desktop)` 실패 ("Local login check failed" → INVALID_CREDENTIALS로 보고되어 PIN 오류처럼 보임, Chromium `pam_authorization_factory_posix.cc` 확인). (2) 10-16 19:49 시도는 진짜 PIN 불일치 ("Verification hash mismatched" — 다른 PIN 입력). PAM 실패 원인 = `/sbin/unix_chkpwd` 소유자가 `100000:100042` (host idmap 잔재, root:shadow여야)라 shadow를 못 읽음. 조치: `chown 0:42 + chmod 2755` (chown이 setgid bit을 날리므로 chmod 필수), `unix_chkpwd sunshine chkexpiry` rc=0 확인. 동일 corruption이 `/usr/bin/passwd` (`100000:100000`)에도 있으나 CRD 경로와 무관하여 미수정.
- 2026-10-16 (CRD host 재등록, PIN reset): 원 PIN 분실 → `start-host` 재등록. 사용자의 터미널에서 직접 실행 (opencode shell은 tty가 없어 내장 sudo/pkexec 실패). 구 host(77b525fb) → 중간(cc36856d, opencode 시도) → 최종(a4a9e8b8) 순으로 Directory에서 자동 교체. `chrome-remote-desktop@sunshine` active, Xorg :20 fresh + Plasma 세션 정상 (스크린샷 wallpaper+panel, dialog 없음). :0 무영향. 접속 PIN=050131.
- 2026-10-16 (permanence 확정): 전 변경 부팅 유지 확인. `gaming-x`가 disabled 상태로 발견 → `enable` (미발견 시 재부팅 후 :0 없음). 최종 부팅 체인: gaming-x + chrome-remote-desktop@ enabled, user units (plasma-x11/sunshine/input-bridge/steam-sync.timer) 전부 enabled. rice 파일(~/.config, ~/.local/share) + polkit rule(8 rules 컴파일 정상) + unix_chkpwd(0:42 2755) + CRD session 파일(+x, xrandr 1080p 블록 포함) + host 등록 모두 디스크 상존. sddm은 기존대로 disabled 유지 (손대지 않음).
- 2026-10-16 (`stream-doctor` 신설, `~/.local/bin/stream-doctor`): streaming/CRD 관리·진단 스크립트. `status` (units+X서버+세션+GPU+disk), `check` (10항목: X0 소켓/1080p-primary/NVIDIA GLX/:0 kwin/compositing OFF/Sunshine 포트/NVENC/CRD host/unix_chkpwd/polkit rule), `restart <all|x|plasma|sunshine|bridge|crd|audio>` (all은 올바른 순서 + stale plasmashell/X소켓 정리 + CRD display 자동감지), `logs <unit>`, `shot [:0|crd]`, `crd-display`. 주의: CRD display는 재시작마다 바뀔 수 있음 (:20→:21 실측) — 스크립트는 ps에서 동적 감지. `check`의 polkit 항목은 root-only dir 특성상 sudo timestamp 없으면 SKIP. 검증 완료 (9 ok + 1 SKIP, rc=0). nvidia/host-conf/SDDM은 건드리지 않음.
- 2026-10-16 (rice + blackout 복구, GPU 실측 RTX 3060 — 기존 1660 SUPER 기록은 구 하드웨어): (a) rice 적용: BreezeDark + Papirus-Dark(user-local `~/.local/share/icons`) + JetBrains Mono(user-local fonts) + Catppuccin-Mocha-Palenight Konsole scheme + VS Code Palenight 폰트 동기화 + 다크 Next 1080p wallpaper + Desktops 1→2. 백업 `~/backup-rice-20261016/`. (b) compositing ON 시도 → headless NVIDIA Xorg에서 KWin이 active=true 보고에도 실제 present가 black (spectacle/xwd/import 전부 black, Moonlight blackout). 원인 확정(A/B: OFF 복귀 즉시 정상). `kwinrc Enabled=false` 유지 — 향후 ON 재시도 금지 (headless DFP-0 + nvidia GLX present 실패). (c) Moonlight blackout의 직접 원인은 kded6/plasmashell의 `org.freedesktop.NetworkManager.network-control` polkit modal (화면 dim → 폰에서 blackout처럼 보임). 조치: `/etc/polkit-1/rules.d/49-sunshine-nm.rules` (user sunshine auto-YES, subject.local 조건 없음 — LXC 세션은 local로 분류 안 됨). (d) CRD :20 bare-black (session 파일 없음 → xterm만). 조치: `~/.chrome-remote-desktop-session` 신설 (`dbus-run-session -- startplasma-x11`), `systemctl start chrome-remote-desktop@sunshine` (CRD 스크립트의 내장 sudo는 tty 필요로 실패하므로 systemctl 직접 실행). :20에 두 번째 Plasma 정상 (kwinrc 공유로 compositing OFF). (e) stale `/tmp/.X11-unix/X1` 제거. 주의: 동일 user 두 Plasma 세션(:0 + :20) 공존 — kwallet unlock prompt 가능성은 NOT VERIFIED.

## Sources

- Proxmox LXC GPU sharing 개념(호스트 드라이버 소유 + 컨테이너 userspace + cgroup/mount): ProxMenux `Add GPU to LXC` (https://proxmenux.com/en/docs/hardware/igpu-acceleration-lxc), Proxmox Forum LXC passthrough guide 2026-06 (https://forum.proxmox.com/threads/proxmox-older-nvidia-gpus-gtx-1060-p4000-v100-lxc-passthrough-guide-updated-june-2026.183835), Mxlted/Proxmox-Nvidia-Drivers (https://github.com/Mxlted/Proxmox-Nvidia-Drivers), Bishop-trevorstuart/Nvidia-Proxmox-LXC-Docker (https://github.com/Bishop-trevorstuart/Nvidia-Proxmox-LXC-Docker). ※ 현재 시스템과 다르면 현재 시스템 우선, 차이는 Notes에 기록.
- NVENC API 요구 버전(13.1 → driver >= 610): rigaya/NVEnc README 요구표, NVIDIA Video Codec SDK 13.1 docs (https://docs.nvidia.com/video-technologies/video-codec-sdk/13.1/index.html), Sunshine `src/nvenc/nvenc_base.cpp` (SDK 선택 로직).
- Sunshine: 공식 docs (https://docs.lizardbyte.dev/projects/sunshine/), GitHub LizardByte/Sunshine (`src/platform/linux/x11grab.cpp` X11 캡처, `docs/getting_started.md` CUDA/X11/udev/`sunshine.service` 예시), issue #2187 (NVENC 실패 사례).
- Debian 13 / KDE Plasma 6 / Xorg 1.21: 본 환경 실측 버전이 우선. 일반 문서는 참고용으로만 사용.

---
다음 agent는 작업 전 `Verification` 섹션부터 실행하고, 호스트 접근 권한이 생기면 `UNKNOWN/NOT VERIFIED` 항목(특히 CTID, PVE 버전, `/etc/pve/lxc/<CTID>.conf`)을 먼저 채울 것.
