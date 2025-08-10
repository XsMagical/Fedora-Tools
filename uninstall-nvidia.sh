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
  printf '%b\n' "${BLUE}   uninstall-nvidia.sh - Revert to Nouveau (by XsMagical)${RESET}"
  printf '%b\n' "${BLUE}   https://github.com/XsMagical/${RESET}"
  printf '%b\n\n' "${BLUE}----------------------------------------------------------${RESET}"
}

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo $0"
    exit 1
  fi
}

have() { command -v "$1" &>/dev/null; }

remove_kernel_args() {
  local args=(
    rd.driver.blacklist=nouveau
    modprobe.blacklist=nouveau
    nouveau.blacklist=1
    nvidia_drm.modeset=1
  )

  if [[ -d /boot/loader || -f /etc/kernel/cmdline ]]; then
    local f=/etc/kernel/cmdline
    [[ -f "$f" ]] || touch "$f"
    local cur
    cur="$(tr -d '\n' < "$f")"
    for a in "${args[@]}"; do
      cur="$(sed -E "s/(^| )$a( |$)/ /g" <<< "$cur")"
    done
    cur="$(sed -E 's/ +/ /g; s/^ //; s/ $//' <<< "$cur")"
    echo "$cur" > "$f"
    bootctl update 2>/dev/null || true
  elif have grubby; then
    for a in "${args[@]}"; do
      grubby --update-kernel=ALL --remove-args="$a" 2>/dev/null || true
    done
  fi
}

main() {
  print_banner
  need_root

  echo -e "${BOLD}Stopping NVIDIA services...${RESET}"
  systemctl disable --now nvidia-persistenced.service 2>/dev/null || true
  systemctl disable --now nvidia-powerd.service 2>/dev/null || true

  echo -e "${BOLD}Removing NVIDIA packages...${RESET}"
  dnf -y remove \
    xorg-x11-drv-nvidia\* nvidia-settings nvidia-persistenced \
    kmod-nvidia\* akmod-nvidia\* || true

  echo -e "${BOLD}Removing Nouveau blacklist (if any)...${RESET}"
  rm -f /etc/modprobe.d/blacklist-nouveau.conf || true

  echo -e "${BOLD}Reverting kernel command line...${RESET}"
  remove_kernel_args

  echo -e "${BOLD}Regenerating initramfs and depmod...${RESET}"
  dracut --regenerate-all --force || true
  depmod -a || true

  echo
  echo -e "${BOLD}MOK cleanup (optional):${RESET}"
  echo "  If you enrolled a custom MOK for signed NVIDIA modules and want to remove it:"
  echo "    sudo mokutil --reset    # then reboot and confirm in the blue menu"
  echo
  echo -e "✅ ${BOLD}Done. Reboot to load the open-source Nouveau driver.${RESET}"
}

main "$@"
