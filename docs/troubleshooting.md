# Troubleshooting — 우선순위 순서 (2026-09-18 기준)

> 원칙: `AGENTS.md`의 `Verification`부터 실행. 추측으로 설정 변경 금지. secret 열람 최소화.

## 0. 공통 전제 (SSH)

현재 SSH 세션에는 `DISPLAY`, `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`가 비어 있다. X11/오디오/user-unit 명령은 매번 명시:

```bash
export DISPLAY=:0
export XDG_RUNTIME_DIR=/run/user/1000
# user unit 예:
XDG_RUNTIME_DIR=/run/user/1000 systemctl --user status sunshine plasma-x11 input-bridge
# Qt 바이너리는 반드시 DISPLAY=:0 와 함께 (없이 실행하면 abort + core dump):
DISPLAY=:0 plasmashell --version  # 6.3.6
```

`LANG=C`이므로 Qt UTF-8 경고는 정상 (무시 가능).

## 1. Host NVIDIA (호스트 접근 시)

```bash
nvidia-smi  # 호스트에서
ls -l /dev/nvidia*  # major 195/511 확인
cat /proc/driver/nvidia/version
```

LXC 내부 대리 확인: `cat /proc/driver/nvidia/version` (595.58.03), `nvidia-smi` (GTX 1660 SUPER).
호스트 conf 최우선: `/etc/pve/lxc/<CTID>.conf`의 `devN`/`lxc.mount.entry`/`lxc.cgroup2.devices.allow`.

## 2. LXC device 가시성

```bash
ls -l /dev/nvidia0 /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm* /dev/dri /dev/uinput
cat /proc/mounts | grep -E "nvidia|dri|uinput|input"
```

없으면 호스트 conf 문제. LXC 내부에서 생성 시도 금지.

## 3. NVIDIA userspace 일치

```bash
cat /var/log/nvidia-installer.log | head -n 30  # 595.58.03 --no-kernel-module 확인
ls -l /usr/lib/x86_64-linux-gnu/libGLX_nvidia.so.595.58.03
DISPLAY=:0 glxinfo | grep -E "direct rendering|OpenGL (vendor|renderer)"
```

host kernel ≠ LXC userspace 버전이면 GLX/Vulkan 깨짐. 재설치는 동일 버전/동일 옵션으로만.

## 4. Xorg

```bash
systemctl status gaming-x  # /usr/bin/Xorg :0, enabled/active
cat /etc/X11/xorg.conf.d/20-nvidia-headless.conf  # DFP-0 1920x1080
head -n 40 /var/log/Xorg.0.log  # 1.21.1.16, nvidia 595.58.03
grep -E "\(EE\)" /var/log/Xorg.0.log  # systemd-logind 1건은 기지 현상
DISPLAY=:0 xrandr  # DP-0, 현재 1024x768 (1920x1080 가능)
ls -l /tmp/.X11-unix/X0
```

`systemctl restart gaming-x`는 전 세션에 영향 → 최후 수단. 수정 전 conf 백업.

## 5. KDE

```bash
XDG_RUNTIME_DIR=/run/user/1000 systemctl --user status plasma-x11
ps aux | grep -E "kwin_x11|plasmashell|startplasma-x11" | grep -v grep
XDG_RUNTIME_DIR=/run/user/1000 journalctl --user -u plasma-x11 -n 50
```

`qdbus` 없음 → compositingActive 직접 조회 불가 (NOT VERIFIED).

## 6. Sunshine service

```bash
XDG_RUNTIME_DIR=/run/user/1000 systemctl --user status sunshine
cat ~/.config/sunshine/sunshine.conf
XDG_RUNTIME_DIR=/run/user/1000 journalctl --user -u sunshine -n 100
```

`Failed to map ... : 501` 반복은 기지 현상 (UPnP). LAN 사용 시 무시 가능, WAN 시 수동 포트포워딩 검토.

## 7. Display capture

```bash
grep -i -E "Screencasting with X11|wayland|portalgrab" ~/.config/sunshine/sunshine.log*
echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"  # 비어 있어야 정상
```

`Screencasting with X11`이 있어야 정상.

## 8. NVENC (현재 핵심 이슈)

```bash
grep -i -E "nvenc|libx264|vaapi|vulkan|Found H.264 encoder" ~/.config/sunshine/sunshine.log*
```

- 2026.906 기준 구 기록: `Required: 13.1 Found: 13.0` + `driver >= 610 required` → nvenc 실패 → `Found H.264 encoder: libx264 [software]`.
- 현 2025.924 기준 정상 (2026-09-18 심야 실측): 부팅 프로브 `Found H.264 encoder: h264_nvenc [nvenc]` 성공.
  `av1_nvenc` 실패는 Turing 정상. 실스트림에서 `libx264`로 떨어지면 보고할 것.
- 드라이버 595→610+ 업그레이드는 현 버전에서 불필요. 호스트 작업이므로 단독 결정 금지는 유지.
- HEVC/AV1은 로그 성공 증거 없음 (NOT VERIFIED). Moonlight 실스트림 없이 단정 금지.

## 9. Input

```bash
XDG_RUNTIME_DIR=/run/user/1000 systemctl --user status input-bridge
ls /sys/class/input/*/name | xargs -I{} sh -c 'echo -n "{}: "; cat {}' | grep -i passthrough
python3 -c "import evdev; print('ok')"
```

가상 3종 (Keyboard/Mouse/Absolute passthrough)이 없으면 Sunshine 재시작 후 재생성 확인.

## 10. Audio

```bash
DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/1000 pactl info  # Default Sink: auto_null
DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/1000 wpctl status  # Dummy Output만
```

물리 싱크를 기대하지 말 것. `sink-sunshine-stereo` 표기는 있으나 원문 대조 NOT VERIFIED.

## 11. Network

```bash
ip -brief addr  # 192.168.1.31/24
ip route  # via 192.168.1.1
ss -tlnp | grep -E "47984|47989|47990|48010"  # TCP 4포트
cat /etc/resolv.conf  # 1.1.1.1/1.0.0.1 (PVE 생성)
```

UDP Sunshine 포트는 평시 미관측 → 스트림 중 `ss -tulpn` 재확인. `iptables`/`nft`는 LXC 내부에 없음.

## 12. 복구 순서

1. LXC 내부 파일부터: Xorg conf → user units → sunshine.conf/apps.json (수정 전 백업, `daemon-reload`).
2. NVIDIA userspace는 동일 버전/옵션으로만.
3. 호스트 작업 (드라이버/conf/reboot)은 PVE 접근 확보 + 별도 승인 후.
