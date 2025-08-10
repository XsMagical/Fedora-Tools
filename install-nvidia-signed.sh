#!/usr/bin/env bash
set -euo pipefail

# ===== Colors =====
RED="\033[31m"; BLUE="\033[34m"; RESET="\033[0m"; BOLD="\033[1m"; DIM="\033[2m"

print_banner() {
  printf '%b\n' "${RED}████████╗███╗   ██╗${RESET}"
  printf '%b\n' "${RED}╚══██╔══╝████╗  ██║${RESET}"
  printf '%b\n' "${RED}   ██║   ██╔██╗ ██║${RESET}"
  printf '%b\n' "${RED}   ██║   ██║╚██╗██║${RESET}"
  printf '%b\n' "${RED}   ██║   ██║ ╚████║${RESET}"
  printf '%b\n' "${RED}   ╚═╝   ╚═╝  ╚═══╝${RESET}"
  printf '%b\n' "${BLUE}----------------------------------------------------------${RESET}"
  printf '%b\n' "${BLUE}   install-nvidia.sh - NVIDIA Driver Install Script${RESET}"
  printf '%b\n' "${BLUE}   by XsMagical | https://github.com/XsMagical/${RESET}"
  printf '%b\n\n' "${BLUE}----------------------------------------------------------${RESET}"
}

have_cmd(){ command -v "$1" &>/dev/null; }

sb_enabled() {
  if have_cmd mokutil && mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
    return 0
  fi
  return 1
}

enable_rpmfusion() {
  local rel; rel="$(rpm -E %fedora)"
  rpm -q rpmfusion-free-release    &>/dev/null || dnf -y install "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${rel}.noarch.rpm"
  rpm -q rpmfusion-nonfree-release &>/dev/null || dnf -y install "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${rel}.noarch.rpm"
  dnf -y makecache
}

swap_ffmpeg_if_needed() {
  rpm -q ffmpeg-free &>/dev/null && dnf -y swap ffmpeg-free ffmpeg --allowerasing || true
}

install_bits() {
  dnf -y install \
    kernel-devel-"$(uname -r)" kernel-headers gcc make dracut \
    akmods openssl nss-tools mokutil \
    xorg-x11-drv-nvidia xorg-x11-drv-nvidia-cuda xorg-x11-drv-nvidia-cuda-libs \
    xorg-x11-drv-nvidia-power nvidia-settings nvidia-persistenced
}

blacklist_nouveau() {
  mkdir -p /etc/modprobe.d
  cat >/etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
}

set_kernel_cmdline() {
  local need=("rd.driver.blacklist=nouveau" "modprobe.blacklist=nouveau" "nouveau.blacklist=1" "nvidia_drm.modeset=1")
  if [[ -d /boot/loader/entries || -f /boot/loader/loader.conf ]]; then
    local f=/etc/kernel/cmdline; [[ -f "$f" ]] || touch "$f"
    local cur; cur="$(tr -d '\n' <"$f")"
    for p in "${need[@]}"; do grep -qw "$p" <<<"$cur" || cur="$cur $p"; done
    echo "$cur" | sed -E 's/ +/ /g;s/^ //' > "$f"
    bootctl update || true
  elif have_cmd grubby; then
    for p in "${need[@]}"; do grubby --info=ALL | grep -qw "$p" || grubby --update-kernel=ALL --args="$p"; done
  fi
  dracut --regenerate-all --force || true
}

ensure_mok_key_if_needed() {
  if ! sb_enabled; then
    echo -e "${DIM}Secure Boot is disabled — skipping MOK key & signing setup.${RESET}"
    return 0
  fi
  local certdir=/etc/pki/akmods/certs
  local privdir=/etc/pki/akmods/private
  local der="$certdir/mok.der"
  local pem="$certdir/mok.pem"
  local key="$privdir/mok.priv"

  mkdir -p "$certdir" "$privdir"
  if [[ ! -s "$der" || ! -s "$key" ]]; then
    echo -e "${DIM}Generating Secure Boot MOK key (10y)…${RESET}"
    openssl req -new -x509 -newkey rsa:4096 -sha256 -days 3650 \
      -subj "/CN=xs@fedora MOK/" \
      -keyout "$key" -out "$pem" -nodes
    openssl x509 -in "$pem" -outform DER -out "$der"
    chmod 0600 "$key"
  fi

  if ! mokutil --list-enrolled 2>/dev/null | grep -q "xs@fedora MOK"; then
    echo -e "${BOLD}Enrolling MOK cert… set a password now; confirm it on next boot (Enroll MOK).${RESET}"
    mokutil --import "$der"
    echo -e "${BLUE}On reboot: Enroll MOK → Continue → Yes → enter the password you set.${RESET}"
  fi
}

build_modules() {
  akmods --force --kernels "$(uname -r)" || true
  depmod -a || true
  dracut --regenerate-all --force || true
}

enable_services() {
  systemctl enable --now nvidia-persistenced.service || true
  systemctl enable --now nvidia-powerd.service 2>/dev/null || true
}

main() {
  print_banner
  [[ $EUID -eq 0 ]] || { echo "Run as root (sudo)."; exit 1; }

  if sb_enabled; then
    echo "Secure Boot: ENABLED — will set up signing."
  else
    echo "Secure Boot: DISABLED — installing unsigned NVIDIA modules."
  fi

  enable_rpmfusion
  swap_ffmpeg_if_needed
  install_bits
  blacklist_nouveau
  set_kernel_cmdline
  ensure_mok_key_if_needed
  build_modules
  enable_services

  echo -e "\n✅ Done."
  if sb_enabled; then
    echo -e "🔁 Reboot and complete **Enroll MOK** to load the signed NVIDIA modules."
  else
    echo -e "🔁 Reboot to start using the NVIDIA driver."
  fi
}

main "$@"
