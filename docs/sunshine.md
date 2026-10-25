# Sunshine — 실측 기록 (2026-09-18)

## 설치

- 버전: `2025.924.154138-1+debiantrixie` (`dpkg -l`, `sunshine --version` commit `86188d47a7463b0f73b35de18a628353adeaa20e`, Publisher LizardByte).
- 소스: `deb https://dl.cloudsmith.io/public/lizardbyte/stable/deb/debian trixie main` (`/etc/apt/sources.list.d/lizardbyte-stable.list`).
- `apt-cache policy sunshine`: Installed 2025.924, Candidate 2026.914.233613 (2026.906.222525, 2026.516 등도 존재). 현재 구버전 유지 중. 구 로그(2026-09-13)에는 2026.906 실행 흔적 → 다운그레이드 정황 (행위자/시점 NOT VERIFIED).
- 실행 파일: `/usr/bin/sunshine`. system unit 없음. user unit만 존재.

## 서비스

`~/.config/systemd/user/sunshine.service`:

```ini
[Unit]
Description=Sunshine
After=plasma-x11.service
Requires=plasma-x11.service
[Service]
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/1000
Environment=__NV_PRIME_RENDER_OFFLOAD=1
Environment=__GLX_VENDOR_LIBRARY_NAME=nvidia
ExecStart=/usr/bin/sunshine
Restart=always
RestartSec=3
[Install]
WantedBy=default.target
```

- 상태 (2026-09-18): enabled, active (running) since 20:59:27, Main PID 2102, user sunshine.
- `journalctl --user -u sunshine`는 `Failed to map TCP/UDP ... : 501` 반복 외에 별다른 에러 없음 (UPnP 실패 — 아래 참조).

## 설정

`~/.config/sunshine/sunshine.conf` (secret 없음, 전문):

```
locale = ko
upnp = enabled
origin_web_ui_allowed = wan
csrf_allowed_origins = https://192.168.1.31:47990,https://<PUBLIC_IP>:47990
external_ip = <PUBLIC_IP>
system_tray = disabled
gamepad = x360
notify_pre_releases = disabled
hevc_mode = 1
```

`~/.config/sunshine/apps.json`: env PATH에 `~/.local/bin` 포함, 앱 5개:

1. Desktop (기본).
2. Low Res Desktop — `xrandr --output HDMI-1 --mode 1920x1080` / undo 1920x1200. **주의: 실제 출력명은 `DP-0` (xrandr 실측). 그대로 실행 시 실패 가능성.**
3. Steam Big Picture — `env STEAM_RUNTIME=1 setsid /usr/games/steam ... steam://open/bigpicture`.
4. Steam Gaming — `/home/sunshine/.local/bin/moonlight-steam` (gamescope probe + Big Picture lifecycle, PRIME/NVAPI env).
5. Firefox — `/usr/bin/firefox` (firefox-esr 140.15).

인증: `credentials/cacert.pem`, `cakey.pem` 존재. `sunshine_state.json`에 salt/password 해시 + 페어링 cert(`ximi`) 포함 → 본 문서에 비기록 (`<REDACTED>`).

## Runtime 검증

- Display capture: 구 로그(`sunshine.log.2`, 2026-09-13)에 `Screencasting with X11` 반복 → X11 캡처 경로 동작. `WAYLAND_DISPLAY` 미정의, `/run/user/1000/wayland*` 없음 → X11 모드 확정.
- Encoder (구 로그, 당시 2026.906 — 현재 2025.924의 인코더 테스트는 현 로그에 없음):
  - `Trying encoder [nvenc]` → `h264_nvenc`: `Driver does not support the required nvenc API version. Required: 13.1 Found: 13.0` + `minimum required Nvidia driver ... 610.00 or newer` → `Could not open codec` → `Encoder [nvenc] failed`.
  - `Trying encoder [vulkan]` → `Could not initialize x11 display with the given hw device type` → failed.
  - `Trying encoder [vaapi]` → `Couldn't initialize va display: unknown libva error` → failed.
  - `Trying encoder [software]` → `libx264` 성공 (`Found H.264 encoder: libx264 [software]`).
  - **결론: NVENC 불가, software fallback이 현재 정상.** 드라이버 595.58.03 < 요구 610. HEVC(`hevc_mode=1`)/AV1 성공 증거 없음 → NOT VERIFIED.
- 현재 로그(`sunshine.log`, 2026-09-18 22:13): 설정 echo만 있고 인코더 테스트 없음. 인코더 상태 재확인이 필요하면 Moonlight 실접속 테스트가 필요 (로그만으로 단정 금지).
- UPnP: `upnp=enabled`이나 2분 간격으로 `Failed to map TCP 48010/47989/47984/47990 + UDP 47998/48000/47999: 501` 반복. 공유기 UPnP 비활성/이중 NAT 가능성. LAN 스트리밍에는 영향 없음.
- 포트 (`ss -tulpn` 실측): TCP `47984/47989/47990/48010` LISTEN. UDP Sunshine 포트는 평시 미관측 → 스트림 중 재확인 필요 (NOT VERIFIED).
- Web UI: `https://192.168.1.31:47990` (origin에 `<PUBLIC_IP>`도 허용). 페어링/설정은 Web UI로만. `sunshine_state.json` 직접 편집 금지.

## Input

- Sunshine 가상 장치 (실측 `evdev`): `Keyboard passthrough` (event9), `Mouse passthrough` (event7), `Mouse passthrough (absolute)` (event8).
- 물리 장치도 동일 `/dev/input`에 보임: `WCH UART TO KB-MS`, `Cooler Master SR4`, Power Button, HDA NVidia/HD-Audio Generic.
- Xorg는 udev가 없어 가상 장치를 직접 못 보므로 `sunshine-input-bridge.py` (user unit `input-bridge.service`, active, Restart always)가 evdev를 읽어 XTest로 `:0`에 재주입. 파일 머리 주석에 이유 명시.
- 의존성: `libevdev2`, `python3-evdev 1.9.1-1`, XTest (`libxtst` — NOT VERIFIED 버전, 다음에 확인할 것).

## Audio

- `pipewire + pipewire-pulse + wireplumber` active (user units, 20:31~).
- `pactl info` (DISPLAY=:0, XDG_RUNTIME_DIR 지정 시): `Server PulseAudio (on PipeWire 1.4.2)`, `Default Sink: auto_null`.
- `wpctl status`: Sink `Dummy Output`만. `Default Configured Devices: Audio/Sink sink-sunshine-stereo` 표기 있음.
- `pactl list sinks short`: `auto_null ... SUSPENDED`. 물리 싱크 없음.
- Sunshine 오디오 싱크 설정 원문 대조는 NOT VERIFIED. `aplay` 없음.

## 관련 파일

- `~/.config/sunshine/sunshine.log*` (로테이션 5개, 2026-09-13 것이 인코더 증거 포함).
- `~/.local/bin/moonlight-steam`: gamescope 캐시 probe (`~/.cache/gamescope-probe`), Big Picture open/close lifecycle, `STEAM_RUNTIME=1`, `PROTON_ENABLE_NVAPI=1`, `__VK_LAYER_NV_optimus=NVIDIA_only` 등.
- `/usr/local/bin/gamescope` 3.16.28 (Debian 패키지 아님, 출처 NOT VERIFIED).
