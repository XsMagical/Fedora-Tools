#!/usr/bin/env bash
# tn_xs_fedora_update_all_script - portable Fedora updater
# - TN banner (red/blue)
# - RPM Fusion enable (optional)
# - Installs missing tools as needed
# - Snap seeding fix + retry
# - pip/cargo/npm run as invoking user
# - Secure Boot: create MOK only if missing (DER import), akmods build, NVIDIA module signing

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
  printf '%b\n' "${BLUE}   Team-Nocturnal.com Fedora Update Script by XsMagical${RESET}"
  printf '%b\n\n' "${BLUE}----------------------------------------------------------${RESET}"
}

log(){ printf '\n==> %s\n' "$*"; }
have(){ command -v "$1" &>/dev/null; }
is_installed(){ rpm -q "$1" &>/dev/null; }

print_banner

# Ask for sudo once (used selectively)
if ! have sudo; then echo "This script needs 'sudo'. Add your user to the wheel group."; exit 1; fi
sudo -v || { echo "Sudo auth failed."; exit 1; }

# Real invoking user (even if run with sudo)
ORIG_USER="${SUDO_USER:-$USER}"
ORIG_HOME="$(getent passwd "$ORIG_USER" | cut -d: -f6)"

# ---------------- Config toggles ----------------
ENABLE_RPMFUSION=${ENABLE_RPMFUSION:-true}
INSTALL_NVIDIA_STACK=${INSTALL_NVIDIA_STACK:-true}
INSTALL_OPTIONAL_MANAGERS=${INSTALL_OPTIONAL_MANAGERS:-true}
# ------------------------------------------------

# Secure Boot signing config
MOK_DIR="/root/secureboot"
MOK_KEY="${MOK_DIR}/MOK.key"       # private key (PEM)
MOK_CRT_PEM="${MOK_DIR}/MOK.pem"   # certificate (PEM)
MOK_CRT_DER="${MOK_DIR}/MOK.cer"   # certificate (DER for mokutil & kmodsign)
SUBJECT="/CN=Robert Secure Boot MOK/"
HASHALG="sha256"

ensure_pkg(){
  local pkgs=("$@") to_install=()
  for p in "${pkgs[@]}"; do is_installed "$p" || to_install+=("$p"); done
  if ((${#to_install[@]})); then
    log "Installing missing packages: ${to_install[*]}"
    sudo dnf install -y "${to_install[@]}"
  fi
}

enable_rpmfusion_if_needed(){
  [[ "$ENABLE_RPMFUSION" == "true" ]] || return
  if ! dnf repolist --enabled | grep -qi 'rpmfusion.*free'; then
    log "Enabling RPM Fusion (free + nonfree)..."
    local VER; VER="$(rpm -E %fedora)"
    sudo dnf install -y \
      "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-${VER}.noarch.rpm" \
      "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${VER}.noarch.rpm"
    ensure_pkg dnf-plugins-core
    sudo dnf config-manager --set-enabled rpmfusion-free rpmfusion-free-updates rpmfusion-nonfree rpmfusion-nonfree-updates || true
  else
    log "RPM Fusion already enabled."
  fi
}

is_atomic(){ have rpm-ostree && rpm-ostree status >/dev/null 2>&1; }
abort_if_atomic(){
  if is_atomic; then
    log "Detected rpm-ostree (atomic) Fedora. Use 'rpm-ostree upgrade' instead. (Ask me for an atomic-safe version.)"
    exit 0
  fi
}

newest_kernel(){ rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core 2>/dev/null | sort -V | tail -n1; }

ensure_snap_ready(){
  [[ "$INSTALL_OPTIONAL_MANAGERS" == "true" ]] || return
  if ! have snap; then
    log "Installing and enabling snapd..."
    ensure_pkg snapd
    sudo systemctl enable --now snapd.socket || true
    [[ -e /snap ]] || sudo ln -s /var/lib/snapd/snap /snap
  fi
  if have snap; then
    # First-run seeding wait + gentle retry
    if ! sudo snap wait system seed.loaded >/dev/null 2>&1; then
      sudo systemctl restart snapd.seeded.service snapd.service snapd.socket || true
      sudo snap wait system seed.loaded >/dev/null 2>&1 || true
    fi
  fi
}

ensure_managers(){
  enable_rpmfusion_if_needed
  ensure_pkg ca-certificates curl coreutils sed grep findutils util-linux

  if [[ "$INSTALL_OPTIONAL_MANAGERS" == "true" ]]; then
    is_installed flatpak || ensure_pkg flatpak
    is_installed python3-pip || ensure_pkg python3-pip
  fi

  ensure_pkg mokutil openssl akmods

  local kver; kver="$(newest_kernel || true)"
  if [[ -n "$kver" ]]; then
    if [[ ! -x "/usr/src/kernels/${kver}/scripts/sign-file" ]] && ! have kmodsign; then
      log "Installing kernel headers for ${kver}..."
      ensure_pkg "kernel-devel-${kver}"
    fi
  fi

  if [[ "$INSTALL_NVIDIA_STACK" == "true" ]] && lspci -nnk | grep -qi nvidia; then
    if ! rpm -qa | grep -q '^akmod-nvidia'; then
      log "NVIDIA GPU detected. Installing akmod-nvidia..."
      ensure_pkg akmod-nvidia
      sudo dnf install -y xorg-x11-drv-nvidia-cuda nvidia-vaapi-driver || true
    else
      log "akmod-nvidia already installed."
    fi
  fi
}

pip_update_user(){
  # Run as invoking user; do nothing if no outdated packages
  sudo -u "$ORIG_USER" HOME="$ORIG_HOME" python3 - <<'PY'
import subprocess, json, sys
try:
    out = subprocess.check_output([sys.executable,"-m","pip","list","--outdated","--format","json","--user"], text=True)
    pkgs = [p["name"] for p in json.loads(out)]
    if not pkgs:
        print("No user pip packages to update.")
    else:
        for name in pkgs:
            subprocess.call([sys.executable,"-m","pip","install","-U","--user",name])
except Exception as e:
    print(e)
PY
}

npm_update_global(){
  if ! have npm; then return; fi
  local prefix; prefix="$(sudo -u "$ORIG_USER" HOME="$ORIG_HOME" npm config get prefix 2>/dev/null || echo)"
  if [[ "$prefix" == "/usr" || "$prefix" == "/usr/local" || "$prefix" == "/usr/lib/node_modules" || "$prefix" == "/usr/local/lib" ]]; then
    sudo npm update -g || true
  else
    sudo -u "$ORIG_USER" HOME="$ORIG_HOME" npm update -g || true
  fi
}

ensure_mok_key(){
  # Only create/import if missing
  if [[ -f "$MOK_KEY" && -f "$MOK_CRT_DER" ]]; then return; fi
  log "Creating MOK keypair in ${MOK_DIR} (one-time)..."
  sudo mkdir -p "$MOK_DIR"
  sudo chmod 700 "$MOK_DIR"
  sudo openssl req -new -x509 -newkey rsa:4096 -keyout "$MOK_KEY" -out "$MOK_CRT_PEM" -nodes -days 3650 -subj "$SUBJECT"
  sudo chmod 600 "$MOK_KEY"
  sudo openssl x509 -in "$MOK_CRT_PEM" -outform DER -out "$MOK_CRT_DER"
  log "Importing MOK cert (enroll on next reboot at the blue MOK screen)..."
  sudo mokutil --import "$MOK_CRT_DER" || true
}

sign_modules_for_kernel(){
  local kver="$1" SIGNFILE=""
  if [[ -x "/usr/src/kernels/${kver}/scripts/sign-file" ]]; then
    SIGNFILE="/usr/src/kernels/${kver}/scripts/sign-file"
  elif [[ -x "/lib/modules/${kver}/build/scripts/sign-file" ]]; then
    SIGNFILE="/lib/modules/${kver}/build/scripts/sign-file"
  elif have kmodsign; then
    SIGNFILE="kmodsign"
  else
    log "sign-file/kmodsign not found; skipping signing."
    return 0
  fi

  if have akmods; then
    log "Building akmods for ${kver} (may take a few minutes)..."
    sudo akmods --force --kernels "$kver" || true
  fi

  local MODDIR="/lib/modules/${kver}"
  mapfile -t MODS < <(find "$MODDIR" -type f -name 'nvidia*.ko*' 2>/dev/null || true)
  if ((${#MODS[@]}==0)); then
    echo "No NVIDIA modules under ${MODDIR}. If using akmod-nvidia, they may appear after reboot."
    return 0
  fi

  log "Signing NVIDIA modules for ${kver}..."
  for m in "${MODS[@]}"; do
    if [[ "$SIGNFILE" == "kmodsign" ]]; then
      sudo kmodsign "$HASHALG" "$MOK_KEY" "$MOK_CRT_DER" "$m"
    else
      sudo "$SIGNFILE" "$HASHALG" "$MOK_KEY" "$MOK_CRT_DER" "$m"
    fi
    if have modinfo; then
      signer=$(modinfo "$m" 2>/dev/null | awk -F': ' '/signer/ {print $2}')
      echo "Signed: $(basename "$m") [signer: ${signer:-unknown}]"
    else
      echo "Signed: $(basename "$m")"
    fi
  done
  log "Module signing complete."
}

flatpak_eol_warn(){
  local EOL_APPS
  EOL_APPS="$(flatpak list --app --columns=application,runtime 2>/dev/null | awk '/org\.gnome\.Platform.*46/ {print $1}' || true)"
  if [[ -n "${EOL_APPS}" ]]; then
    echo "WARNING: These Flatpak apps still use EOL runtime org.gnome.Platform//46:"
    echo "${EOL_APPS}"
    echo "→ Update or switch source (RPM/newer Flatpak) to move off 46."
  fi
}

# ---------------- Main ----------------
abort_if_atomic

log "Preparing system (ensuring repos, tools, and dependencies)..."
ensure_managers
ensure_snap_ready

log "Updating via DNF..."
sudo dnf upgrade --refresh -y || true

if have flatpak; then
  log "Updating Flatpak apps and runtimes..."
  flatpak update -y || true
  log "Pruning unused Flatpak runtimes..."
  flatpak uninstall --unused -y || true
  flatpak_eol_warn
fi

# Snap refresh (after seeding)
if have snap; then
  log "Updating Snap packages..."
  if ! sudo snap wait system seed.loaded >/dev/null 2>&1; then
    echo "Snapd not seeded yet; skipping snap refresh this run."
  else
    sudo snap refresh || true
  fi
fi

if have python3; then
  log "Updating Python user packages (pip)..."
  pip_update_user || true
fi

if have cargo; then
  log "Updating cargo installs..."
  sudo -u "$ORIG_USER" HOME="$ORIG_HOME" bash -lc '
    if ! command -v cargo-install-update >/dev/null 2>&1; then
      cargo install cargo-update || true
    fi
    cargo install-update -a || true
  '
fi

log "Updating global npm packages (if present)..."
npm_update_global

# Secure Boot path
SECUREBOOT_STATE="unknown"
if have mokutil; then SECUREBOOT_STATE="$(mokutil --sb-state 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"; fi

if grep -q "enabled" <<<"$SECUREBOOT_STATE"; then
  log "Secure Boot detected: ${SECUREBOOT_STATE}"
  ensure_mok_key
  NEWEST_KVER="$(newest_kernel || true)"
  if [[ -n "${NEWEST_KVER}" ]]; then
    log "Newest installed kernel: ${NEWEST_KVER}"
    sign_modules_for_kernel "${NEWEST_KVER}"
  else
    echo "No installed kernels found; skipping signing."
  fi
else
  log "Secure Boot not enabled (or mokutil missing). Skipping signing."
fi

printf '%b\n' "\n${BOLD}✅ All updates complete!${RESET}"
