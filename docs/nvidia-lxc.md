# NVIDIA + LXC GPU Sharing — 실측 기록 (2026-09-18)

## GPU 실체

- `lspci -nnk`: `0a:00.0 VGA TU116 [GeForce GTX 1660 SUPER] [10de:21c4] rev a1, sub MSI [1462:c75a]`, `Kernel driver in use: nvidia`.
- 함께 보이는 기능: `0a:00.1 Audio (snd_hda_intel)`, `0a:00.2 USB (xhci_hcd)`, `0a:00.3 UCSI (nvidia-gpu)`.
- `/proc/driver/nvidia/gpus/0000:0a:00.0/information`: TU116-B, VRAM 6291456kB(6144MiB), BIOS 90.16.48.00.2e, PCIe 16X, UUID `GPU-4a2df2e6-e714-7b31-fb72-bc972d8cd0ca`.
- `/proc/driver/nvidia/version`: `NVRM 595.58.03 Tue Mar 17 19:54:55 UTC 2026`.
- `nvidia-smi`: Driver 595.58.03, CUDA Version 13.2 (Toolkit 아님), P8 34C 16W, 4057MiB/6144MiB 사용이나 `No running processes found` (불일치 — Known Issue).

## Device nodes (LXC 내부)

```
crw-rw-rw- root:root 195,0   /dev/nvidia0
crw-rw-rw- root:root 195,255 /dev/nvidiactl
crw-rw-rw- root:root 195,254 /dev/nvidia-modeset
crw-rw-rw- root:root 511,0   /dev/nvidia-uvm
crw-rw-rw- root:root 511,1   /dev/nvidia-uvm-tools
cr-------- root:root 236,1   /dev/nvidia-caps/nvidia-cap1
cr--r--r-- root:root 236,2   /dev/nvidia-caps/nvidia-cap2
crw-rw---- root:video    226,1   /dev/dri/card1
crw-rw-rw- root:postdrop 226,128 /dev/dri/renderD128
crw-rw-rw- root:root 10,223 /dev/uinput
```

- `/proc/driver/nvidia/params`: `DeviceFileUID 0, GID 0, Mode 438(0666)` → 위 0666과 일치.
- `/dev/dri/by-path`: `pci-0000:0a:00.0-card → ../card1`, `pci-0000:0a:00.0-render → ../renderD128`.

## Sharing 방식 판정: LXC device sharing (bind-mount)

- `/proc/mounts` 증거: `udev on /dev/nvidia0(nvidiactl/nvidia-uvm/nvidia-uvm-tools/nvidia-caps/dri/uinput/input/nvidia-modeset/uhid) type devtmpfs`. 호스트 udev를 그대로 바인드한 형태.
- VFIO 바인딩 아님 (GPU가 host driver에 그대로 있음).
- `modinfo` 없음 (LXC에서 커널 모듈 관리 불가). 커널 모듈은 host 소유.
- LXC userspace 설치: `/var/log/nvidia-installer.log` (2026-09-13 05:00:21, installer 595.58.03):
  `./nvidia-installer --no-kernel-module --no-dkms --no-systemd --no-backup --no-nvidia-modprobe --install-libglvnd --install-compat32-libs --no-nouveau-check -s`.
- 호스트 conf 원문 (`lxc.cgroup2.devices.allow`, `lxc.mount.entry`, `devN`)은 LXC 내부에서 볼 수 없음 → NOT VERIFIED. 호스트 접근 시 `/etc/pve/lxc/<CTID>.conf` 최우선 확인.
- NVIDIA Container Toolkit: LXC 내부 흔적 없음. 호스트 여부는 NOT VERIFIED.
- CTID: 루트 디스크 `/dev/mapper/data-vm--3001--disk--0`로 3001 추정만 가능. 확정 금지.
- Privileged: `/proc/self/uid_map = 0 0 4294967295` + 전체 lspci 가시 → privileged 정황이나 호스트 conf 없이는 NOT VERIFIED.

## Userspace 상세

- dpkg 소유 아님: `dpkg -S /usr/lib/xorg/modules/drivers/nvidia_drv.so` → not found.
- 파일 (2026-09-13 14:00): `libEGL_nvidia.so.595.58.03`, `libGLX_nvidia.so.595.58.03`, `libGLESv2_nvidia.so.595.58.03`, `nvidia_drv.so` (3.6MB), `libglxserver_nvidia.so`, `/usr/share/glvnd/egl_vendor.d/10_nvidia.json` (`library_path: libEGL_nvidia.so.0`).
- GLX 검증: `DISPLAY=:0 glxinfo` → direct Yes, vendor NVIDIA, renderer `GTX 1660 SUPER/PCIe/SSE2`, core 4.6.0 NVIDIA 595.58.03, VRAM 6144MB 중 1687MB available.
- Vulkan: 시스템 icd.d에 nvidia 없음. `/home/sunshine/nvidia-vk/nvidia_icd.json` (api 1.4.329, library_path가 해당 디렉토리의 libGLX_nvidia 심볼릭링크). 어떤 프로세스가 `VK_ICD_FILENAMES`로 지정하는지는 NOT VERIFIED.
- PRIME: `__GLX_VENDOR_LIBRARY_NAME=nvidia`, `__NV_PRIME_RENDER_OFFLOAD=1` (`~/.xsessionrc`, `~/.profile`, sunshine.service, moonlight-steam).
- CUDA Toolkit: `nvcc` 없음, `/usr/local/cuda*` 없음 → 미설치. `nvidia-smi`의 CUDA 13.2는 드라이버 지원 버전일 뿐.

## 권한/그룹

- user `sunshine`: `video, render, input, sudo, _ssh, postdrop`.
- `/dev/input/event*` group이 `_ssh` (이례적). `/dev/dri/card1` group `video`, `renderD128` group `postdrop`.
- `/etc/udev/rules.d/99-gaming.rules`: `KERNEL=="renderD128", MODE="0666"`, `KERNEL=="uinput", MODE="0666"`. nvidia/input 규칙 없음.
- `gaming-x.service`의 ExecStartPre에서 `chmod 666 /dev/dri/renderD128 /dev/uinput` 재적용 (udev 없이 권한 유지용으로 보임).

## 재현/복구 시 주의

- userspace 재설치는 반드시 동일 버전(595.58.03) + 동일 옵션(`--no-kernel-module` 필수). 커널 모듈 설치 시도는 호스트를 깨뜨릴 수 있으므로 금지.
- host kernel과 LXC userspace 버전 불일치 시 GLX/Vulkan 깨짐. 먼저 `cat /proc/driver/nvidia/version` 대조.
