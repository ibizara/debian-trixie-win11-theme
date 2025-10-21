#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────
ok()    { printf "\033[32m✓\033[0m %s\n" "$*"; }
info()  { printf "\033[36m[i]\033[0m %s\n" "$*"; }
warn()  { printf "\033[33m[!]\033[0m %s\n" "$*"; }
err()   { printf "\033[31m[x]\033[0m %s\n" "$*"; }
ask_yn(){ # ask_yn "Question" default(y/n)
  local q="$1" def="${2:-y}" ans
  read -rp "$q ${def^^}/$( [[ $def = y ]] && echo N || echo Y ): " ans || true
  ans="${ans:-$def}"; [[ "${ans,,}" =~ ^y ]]
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; return 1; }; }

# ──────────────────────────────────────────────────────────────────────────────
# Pre-flight: ensure we're on Debian Trixie (warn otherwise)
# ──────────────────────────────────────────────────────────────────────────────
preflight_os_check() {
  local id="" codename="" pretty=""
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-}"; codename="${VERSION_CODENAME:-}"; pretty="${PRETTY_NAME:-$ID}"
  else
    pretty="$(uname -sr)"
  fi

  if [[ "$id" != "debian" || "$codename" != "trixie" ]]; then
    warn "This script is designed for Debian Trixie. Detected: ${pretty}${codename:+ ($codename)}."
    ask_yn "Do you want to continue anyway?" n || { info "Aborting."; exit 2; }
  else
    ok "Detected Debian Trixie."
  fi
}

preflight_os_check

# Re-run this script with sudo for a *single* line? Not allowed; user asked to keep sudo per line.
# We’ll therefore prefix root actions with sudo (or su -c early on where sudo may not exist).

# ──────────────────────────────────────────────────────────────────────────────
# [1/12] ADD USER TO PASSWORDLESS SUDO
# ──────────────────────────────────────────────────────────────────────────────
step_sudo_nopass() {
  info "[1/12] Ensuring passwordless sudo for group 'sudo'…"
  local DROPIN="/etc/sudoers.d/sudogroup"
  local LINE="%sudo ALL=(ALL:ALL) NOPASSWD: ALL"

  echo "NOTE: You will be prompted for the ROOT (administrator) password."

  # Make sure sudo exists (still via su; no sudo used yet)
  if ! command -v sudo >/dev/null 2>&1; then
    su -c 'PATH=/usr/sbin:/usr/bin:/sbin:/bin; apt update && apt install -y sudo'
  fi

  # Create/validate drop-in using a single su -c so there’s only one root prompt
  if [ ! -f "$DROPIN" ]; then
    su -c "PATH=/usr/sbin:/usr/bin:/sbin:/bin; {
      printf '%s\n' '$LINE' > '$DROPIN' &&
      chmod 0440 '$DROPIN' &&
      chown root:root '$DROPIN' &&
      /usr/sbin/visudo -cf '$DROPIN' &&
      /usr/sbin/visudo -c
    }"
    ok "sudoers drop-in installed and validated."
  else
    ok "sudoers drop-in already present."
  fi

  # Find default user (UID 1000)
  local USER_1000
  USER_1000="$(getent passwd 1000 | cut -d: -f1 || true)"
  if [[ -z "$USER_1000" ]]; then
    err "No user with UID 1000 found. Cannot add to sudo group."
    exit 40
  fi

  # If user not in sudo group yet, add them and hard-stop until reboot
  if ! id -nG "$USER_1000" | grep -qw sudo; then
    info "Adding $USER_1000 to group sudo…"
    su -c "PATH=/usr/sbin:/usr/bin:/sbin:/bin; /usr/sbin/usermod -aG sudo '$USER_1000'"

    # Force a reboot gate — do not continue until the reboot happens
    read -r -p 'Reboot now to apply group changes? [y/N]: ' ans
    case "${ans,,}" in
      y|yes)
        echo "Rebooting now… (you may be asked for the ROOT password again)"
        exec su -c 'PATH=/usr/sbin:/usr/bin:/sbin:/bin; /sbin/reboot'
        ;;
      *)
        echo "Reboot declined. Please reboot manually before continuing."
        exit 50
        ;;
    esac
  else
    ok "User $USER_1000 is already in group sudo."
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# [2/12] GNOME TERMINAL SHORTCUT (Ctrl+Alt+T)
# ──────────────────────────────────────────────────────────────────────────────
step_gnome_shortcut() {
  info "[2/12] Setting GNOME custom shortcut for Terminal (Ctrl+Alt+T)…"
  local SCHEMA="org.gnome.settings-daemon.plugins.media-keys"
  local KEY="custom-keybindings"
  local BASE="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings"
  local PATH_CB="$BASE/custom-terminal/"
  local NAME="Terminal"
  local CMD="/usr/bin/gnome-terminal"
  local BIND="<Primary><Alt>t"

  need_cmd gsettings || return 0
  [[ -x "$CMD" ]] || { warn "Not found: $CMD"; return 0; }

  local current
  current="$(gsettings get "$SCHEMA" "$KEY" | sed 's/^@as //')"

  case "$current" in
    *"$PATH_CB"*) : ;;
    "[]") gsettings set "$SCHEMA" "$KEY" "['$PATH_CB']" ;;
    *)    gsettings set "$SCHEMA" "$KEY" "$(echo "$current" | sed "s/]$/, '$PATH_CB']/")" ;;
  esac

  gsettings set "$SCHEMA".custom-keybinding:"$PATH_CB" name "$NAME"
  gsettings set "$SCHEMA".custom-keybinding:"$PATH_CB" command "$CMD"
  gsettings set "$SCHEMA".custom-keybinding:"$PATH_CB" binding "$BIND"
  ok "Shortcut set: $BIND → $CMD"
}

# ──────────────────────────────────────────────────────────────────────────────
# [3/12] GNOME TERMINAL: WHITE ON BLACK
# ──────────────────────────────────────────────────────────────────────────────
step_gnome_terminal_theme() {
  info "[3/12] Setting GNOME Terminal white-on-black…"
  local PL=org.gnome.Terminal.ProfilesList
  local SC=org.gnome.Terminal.Legacy.Profile
  local BASE=/org/gnome/terminal/legacy/profiles:/

  need_cmd gsettings || return 0

  mapfile -t UUIDS < <(gsettings get $PL list | tr -d "[]',@" | xargs -n1 echo | sed '/^$/d')
  local DEF_UUID; DEF_UUID="$(gsettings get $PL default | tr -d "'")"
  local TARGET=""
  for u in "${UUIDS[@]}"; do
    local name
    name="$(gsettings get ${SC}:$BASE:$u/ visible-name | tr -d "'")"
    if printf '%s\n' "$name" | grep -qiE '^unnamed$'; then TARGET="$u"; break; fi
  done
  TARGET="${TARGET:-$DEF_UUID}"
  [[ -n "$TARGET" ]] || { warn "No GNOME Terminal profiles found."; return 0; }

  gsettings set ${SC}:$BASE:$TARGET/ visible-name 'Default'
  gsettings set $PL default "$TARGET"
  gsettings set ${SC}:$BASE:$TARGET/ use-theme-colors false
  gsettings set ${SC}:$BASE:$TARGET/ foreground-color 'rgb(255,255,255)'
  gsettings set ${SC}:$BASE:$TARGET/ background-color 'rgb(0,0,0)'
  gsettings set ${SC}:$BASE:$TARGET/ bold-color-same-as-fg true
  gsettings set ${SC}:$BASE:$TARGET/ palette "['#000000', '#CC0000', '#4E9A06', '#C4A000', '#3465A4', '#75507B', '#06989A', '#D3D7CF', '#555753', '#EF2929', '#8AE234', '#FCE94F', '#729FCF', '#AD7FA8', '#34E2E2', '#EEEEEC']"
  ok "GNOME Terminal profile set."
}

# ──────────────────────────────────────────────────────────────────────────────
# [4/12] UPDATE DEBIAN SOURCES (Deb822) + apt update/upgrade
# ──────────────────────────────────────────────────────────────────────────────
step_sources() {
  info "[4/12] Updating Debian sources (Trixie, Deb822)…"

  if [ -f /etc/apt/sources.list ]; then
    sudo mv -n /etc/apt/sources.list "/etc/apt/sources.list.bak.$(date -Iseconds)"
    ok "Backed up /etc/apt/sources.list"
  fi

  sudo mkdir -p /etc/apt/sources.list.d

  cat <<'EOF' | sudo tee /etc/apt/sources.list.d/debian.sources >/dev/null
Types: deb deb-src
URIs: https://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main non-free-firmware contrib non-free
Enabled: yes
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb deb-src
URIs: https://security.debian.org/debian-security
Suites: trixie-security
Components: main non-free-firmware contrib non-free
Enabled: yes
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

  sudo chmod 0644 /etc/apt/sources.list.d/debian.sources
  ok "Installed /etc/apt/sources.list.d/debian.sources"

  info "Running apt update/upgrade…"
  sudo apt update
  sudo apt -y upgrade
  ok "APT cache updated and system upgraded."
}

# ──────────────────────────────────────────────────────────────────────────────
# [5/12] INSTALL HANDY APPS
# ──────────────────────────────────────────────────────────────────────────────
step_apps() {
  info "[5/12] Installing handy apps…"
  sudo apt install -y \
    curl firmware-linux firmware-linux-nonfree font-manager git htop \
	nautilus-admin p7zip-full rsync vlc wget
  ok "Apps installed."
}

# ──────────────────────────────────────────────────────────────────────────────
# [6/12] CRYPT GUI (Plymouth + GRUB edits)
#   • Install plymouth-themes, set bgrt
#   • Ensure 'plymouth' in initramfs modules
#   • GRUB_TIMEOUT=3
#   • Ensure GRUB_CMDLINE_LINUX_DEFAULT has 'quiet splash' (adds 'splash' after 'quiet' if missing)
# ──────────────────────────────────────────────────────────────────────────────
step_crypt_gui() {
  info "[6/12] Setting up Plymouth + GRUB for encrypted boot GUI…"

  sudo apt-get update -y || true
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y plymouth-themes
  if [[ -d /sys/firmware/efi ]] && [[ -r /sys/firmware/acpi/tables/BGRT ]]; then
    sudo plymouth-set-default-theme -R bgrt
  else
    sudo plymouth-set-default-theme -R spinner
  fi

  # Ensure modules entry
  echo 'plymouth' | sudo tee -a /etc/initramfs-tools/modules >/dev/null
  # De-duplicate the line (safe, optional)
  sudo awk '!x[$0]++' /etc/initramfs-tools/modules | sudo tee /etc/initramfs-tools/modules >/dev/null

  # GRUB edits — in-place, no temp files
  local GRUB=/etc/default/grub

  # Set/append GRUB_TIMEOUT=3
  if sudo grep -q '^GRUB_TIMEOUT=' "$GRUB"; then
    sudo sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' "$GRUB"
  else
    sudo sh -c "printf '%s\n' 'GRUB_TIMEOUT=3' >> '$GRUB'"
  fi

  # Ensure GRUB_CMDLINE_LINUX_DEFAULT exists
  if ! sudo grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB"; then
    sudo sh -c "printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash\"' >> '$GRUB'"
  else
    # Ensure 'quiet' present
    sudo sed -i -E \
      '/^GRUB_CMDLINE_LINUX_DEFAULT=/{
         /"([^"]*(^| )quiet( |$)[^"]*)"/! s/^(GRUB_CMDLINE_LINUX_DEFAULT=")([^"]*)(")/\1\2 quiet\3/
       }' "$GRUB"

    # If 'splash' missing, insert it *right after* the first 'quiet'
    sudo sed -i -E \
      '/^GRUB_CMDLINE_LINUX_DEFAULT=/{
         /"([^"]*(^| )splash( |$)[^"]*)"/! s/^(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*?)\bquiet\b([^"]*")/\1quiet splash\2/
       }' "$GRUB"

    # Normalise spaces inside the quoted value
    sudo sed -i -E '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/  +/ /g' "$GRUB"
    sudo sed -i -E '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/ +"$/"/' "$GRUB"
  fi

  # cryptsetup initramfs flags
  sudo mkdir -p /etc/cryptsetup-initramfs
  local HOOK=/etc/cryptsetup-initramfs/conf-hook
  { echo 'CRYPTSETUP=y'; echo 'PLYMOUTH=y'; } | sudo tee -a "$HOOK" >/dev/null
  sudo awk '!x[$0]++' "$HOOK" | sudo tee "$HOOK" >/dev/null

  sudo update-initramfs -u -k all
  sudo update-grub
  ok "Crypt GUI configured."
}

# ──────────────────────────────────────────────────────────────────────────────
# [7/12] IMPORT WINDOWS FONTS INTO THE SYSTEM
#   • Copies from repo-local Windows/Fonts/{Cloud Fonts,Windows Fonts}
#   • Installs to /usr/local/share/fonts/{WindowsCloud,Windows}
#   • Updates font cache
# ──────────────────────────────────────────────────────────────────────────────
step_import_windows_fonts() {
  info "[7/12] Importing Windows fonts into /usr/local/share/fonts/…"

  # Resolve script directory (handles symlinks & spaces)
  local script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

  # Sources (as produced by your Windows Assets.ps1)
  local SRC_CLOUD="$script_dir/Windows/Fonts/Cloud Fonts"
  local SRC_WIN="$script_dir/Windows/Fonts/Windows Fonts"

  # Destinations
  local DST_BASE="/usr/local/share/fonts"
  local DST_CLOUD="$DST_BASE/WindowsCloud"
  local DST_WIN="$DST_BASE/Windows"

  # Create destinations
  sudo install -d -m 0755 "$DST_CLOUD" "$DST_WIN"

  # Helper to copy if source exists
  copy_fonts() {
    local src="$1" dst="$2" label="$3"
    if [ -d "$src" ]; then
      info "Copying $label from: $src"
      # Copy recognised font file types
      shopt -s nullglob
      mapfile -t files < <(find "$src" -type f \( -iname '*.ttf' -o -iname '*.otf' -o -iname '*.ttc' -o -iname '*.otc' -o -iname '*.fnt' -o -iname '*.fon' \) -print)
      if ((${#files[@]})); then
        # Use rsync if present for speed; otherwise, fall back to install
        if command -v rsync >/dev/null 2>&1; then
          sudo rsync -a --no-perms --no-owner --no-group --chmod=Du=rwx,Fu=rw -- "$src"/ "$dst"/
        else
          # Preserve only mode 0644 for files
          while IFS= read -r -d '' f; do
            sudo install -m 0644 -D -- "$f" "$dst/$(basename "$f")"
          done < <(printf '%s\0' "${files[@]}")
        fi
        ok "Copied ${#files[@]} $label fonts."
      else
        warn "No font files found in: $src"
      fi
    else
      warn "Source not found: $src (skipping $label)"
    fi
  }

  copy_fonts "$SRC_CLOUD" "$DST_CLOUD" "Cloud"
  copy_fonts "$SRC_WIN"   "$DST_WIN"   "Windows"

  # Refresh font cache
  if command -v fc-cache >/dev/null 2>&1; then
    info "Refreshing font cache (fc-cache -f)…"
    sudo fc-cache -f
    ok "Font cache updated."
  else
    warn "fc-cache not found; install 'fontconfig' if fonts are not visible."
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# [8/12] INSTALL WALLPAPERS + SET GNOME BACKGROUND (Light=img0.jpg, Dark=img19.jpg)
#   • Copies ./Windows/Wallpaper/* to /usr/share/backgrounds/Win11
#   • Sets org.gnome.desktop.background picture-uri (+ -dark)
# ──────────────────────────────────────────────────────────────────────────────
step_install_wallpapers() {
  info "[8/12] Installing wallpapers and setting GNOME background…"

  # Resolve script directory (handles symlinks & spaces)
  local script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

  local SRC="$script_dir/Windows/Wallpaper"
  local DST="/usr/share/backgrounds/Win11"

  if [ ! -d "$SRC" ]; then
    warn "Source not found: $SRC"
    return 0
  fi

  sudo install -d -m 0755 "$DST"

  shopt -s nullglob
  mapfile -t wp_files < <(find "$SRC" -maxdepth 1 -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.bmp' -o -iname '*.tif' -o -iname '*.tiff' \) \
    -print | sort)
  if ((${#wp_files[@]} == 0)); then
    warn "No image files found in: $SRC"
    return 0
  fi

  # Copy wallpapers
  local copied=0 f
  for f in "${wp_files[@]}"; do
    sudo install -m 0644 -D -- "$f" "$DST/$(basename -- "$f")"
    ((copied++))
  done
  ok "Copied $copied wallpapers to $DST."

  # Determine URIs for light/dark
  local light_img dark_img
  light_img="$DST/img0.jpg"
  dark_img="$DST/img19.jpg"

  # Fallbacks if missing
  if [ ! -f "$light_img" ]; then
    light_img="$DST/$(basename -- "${wp_files[0]}")"
    warn "img0.jpg not found; using $(basename -- "$light_img") as light wallpaper."
  fi
  if [ ! -f "$dark_img" ]; then
    dark_img="$DST/$(basename -- "${wp_files[-1]}")"
    warn "img19.jpg not found; using $(basename -- "$dark_img") as dark wallpaper."
  fi

  # Apply via GNOME
  if command -v gsettings >/dev/null 2>&1; then
    local light_uri="file://$light_img"
    local dark_uri="file://$dark_img"

    gsettings set org.gnome.desktop.background picture-uri "$light_uri" || true
    gsettings set org.gnome.desktop.background picture-uri-dark "$dark_uri" || true
    gsettings set org.gnome.desktop.background picture-options 'zoom' || true

    ok "GNOME wallpapers set: light → $(basename -- "$light_img"), dark → $(basename -- "$dark_img")."
  else
    warn "gsettings not available; skipped setting GNOME backgrounds."
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# [9/12] INSTALL WIN11 ICON THEME (auto-download if zip missing)
#   • Uses ./Linux/Win11-icon-theme-main.zip if present
#   • Else downloads latest main.zip from GitHub to that path (cached)
#   • Extracts to /tmp, runs install.sh as root → /usr/share/icons, name=Win11
#   • Cleans up and sets GNOME icon theme
# ──────────────────────────────────────────────────────────────────────────────
step_install_icon_theme() {
  info "[9/12] Installing Win11 icon theme…"

  local script_dir zip tmp extract_root
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
  zip="$script_dir/Linux/Win11-icon-theme-main.zip"

  mkdir -p "$script_dir/Linux"

  # If the zip isn't present, download the current branch archive
  if [ ! -f "$zip" ]; then
    info "No local archive found. Downloading from GitHub…"
    local url="https://github.com/yeyushengfan258/Win11-icon-theme/archive/refs/heads/main.zip" # branch archive
    if command -v curl >/dev/null 2>&1; then
      curl -L --fail -o "$zip" "$url"
    elif command -v wget >/dev/null 2>&1; then
      wget -O "$zip" "$url"
    else
      warn "curl/wget not found; installing curl…"
      sudo apt-get update -y >/dev/null 2>&1 || true
      sudo apt-get install -y curl
      curl -L --fail -o "$zip" "$url"
    fi
    ok "Downloaded: $zip"
  else
    info "Using existing archive: $zip"
  fi

  # Extraction helper (prefer 7z; else unzip; install unzip if needed)
  extract_zip() {
    local z="$1" out="$2"
    if command -v 7z >/dev/null 2>&1; then
      7z x -y -o"$out" -- "$z" >/dev/null
    elif command -v unzip >/dev/null 2>&1; then
      unzip -qq -o "$z" -d "$out"
    else
      info "Installing 'unzip' to extract zip…"
      sudo apt-get update -y >/dev/null 2>&1 || true
      sudo apt-get install -y unzip
      unzip -qq -o "$z" -d "$out"
    fi
  }

  tmp="$(mktemp -d /tmp/win11-icons.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  extract_zip "$zip" "$tmp"

  # Find the extracted top-level directory robustly
  extract_root="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  if [ -z "$extract_root" ] || [ ! -d "$extract_root" ]; then
    err "Could not locate extracted theme directory."
    return 1
  fi

  if [ ! -f "$extract_root/install.sh" ]; then
    err "install.sh not found in $extract_root"
    return 1
  fi

  chmod +x "$extract_root/install.sh" || true
  info "Running theme installer as root…"
  # Installer supports --dest and --name; install system-wide and call it 'Win11'
  (cd "$extract_root" && sudo ./install.sh --dest /usr/share/icons --name Win11)

  ok "Icon theme installed."

  # Set GNOME icon theme (fallback to autodetect if 'Win11' isn’t the final dir name)
  if command -v gsettings >/dev/null 2>&1; then
    local chosen="Win11"
    if [ ! -d "/usr/share/icons/$chosen" ]; then
      local candidate
      candidate="$(
        grep -i -H '^[[:space:]]*Name=.*Win[[:space:]]*11' /usr/share/icons/*/index.theme 2>/dev/null \
          | head -n1 | awk -F'/' '{print $(NF-1)}'
      )"
      [ -n "$candidate" ] && chosen="$candidate"
    fi
    gsettings set org.gnome.desktop.interface icon-theme "$chosen" || true
    ok "GNOME icon theme set to '$chosen'."
  else
    warn "gsettings not available; skipped setting icon theme."
  fi

  # Refresh icon caches if needed (installer usually handles this)
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    for d in /usr/share/icons/Win11 /usr/share/icons/Win11*; do
      [ -d "$d" ] && sudo gtk-update-icon-cache -f "$d" || true
    done
  fi
}


# ──────────────────────────────────────────────────────────────────────────────
# [10/12] SET USER PROFILE PHOTO (AccountsService)
#   • Copies ./Windows/User Profile Photo/user.png and registers it
# ──────────────────────────────────────────────────────────────────────────────
step_set_profile_photo() {
  info "[10/12] Setting user profile photo…"

  local script_dir img USER_1000 icon_path user_ini
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
  img="$script_dir/Windows/User Profile Photo/user.png"

  if [ ! -f "$img" ]; then
    err "Profile image not found: $img"
    return 1
  fi

  USER_1000="$(getent passwd 1000 | cut -d: -f1 || true)"
  if [[ -z "$USER_1000" ]]; then
    err "No user with UID 1000 found. Cannot set profile photo."
    return 1
  fi

  icon_path="/var/lib/AccountsService/icons/$USER_1000"
  user_ini="/var/lib/AccountsService/users/$USER_1000"

  # Copy the image and apply metadata
  sudo install -D -m 0644 -- "$img" "$icon_path"
  sudo chown root:root "$icon_path"

  # Ensure an ini with [User] section exists and set Icon=…
  if sudo test -f "$user_ini"; then
    # Replace or add Icon= line
    if sudo grep -q '^Icon=' "$user_ini"; then
      sudo sed -i "s|^Icon=.*$|Icon=$icon_path|" "$user_ini"
    else
      # Ensure [User] section exists
      if ! sudo grep -q '^\[User\]' "$user_ini"; then
        echo "[User]" | sudo tee -a "$user_ini" >/dev/null
      fi
      echo "Icon=$icon_path" | sudo tee -a "$user_ini" >/dev/null
    fi
  else
    # Create a minimal file
    sudo install -D -m 0644 /dev/null "$user_ini"
    {
      echo "[User]"
      echo "Icon=$icon_path"
    } | sudo tee "$user_ini" >/dev/null
  fi
  sudo chown root:root "$user_ini"
  sudo chmod 0644 "$user_ini"

  ok "Profile photo set for $USER_1000. You may need to log out and back in to see it."
}

# ──────────────────────────────────────────────────────────────────────────────
# [11/12] GNOME EXTENSIONS + MANAGER + TWEAKS
#   • Installs extension packages + gnome-shell-extension-manager + gnome-tweaks
#   • Enables extensions via gsettings where possible
#   • Prompts to log off when complete so changes apply cleanly
# ──────────────────────────────────────────────────────────────────────────────
step_gnome_extensions() {
  info "[11/12] Installing GNOME extensions, Manager, and Tweaks…"

  sudo apt update
  sudo apt install -y \
    gir1.2-gmenu-3.0 \
    gnome-shell-extension-desktop-icons-ng \
    gnome-shell-extension-dash-to-panel \
    gnome-shell-extension-blur-my-shell \
    gnome-shell-extension-user-theme \
    gnome-shell-extension-light-style \
    gnome-shell-extension-manager \
    gnome-shell-extension-prefs \
    gnome-tweaks \
    breeze-cursor-theme
    # gnome-shell-extension-arc-menu \  # Debian package (v65) misaligns icons.
    # NOTE: ArcMenu v65 in Debian has a bug causing left-aligned icons.
    # Until Debian updates, we install the current stable v67.2 manually below.

  ok "Packages installed."
  
  # ArcMenu manual install (latest from GNOME Extensions)
  local ARC_URL="https://extensions.gnome.org/extension-data/arcmenuarcmenu.com.v69.shell-extension.zip"
  local ARC_UUID="arcmenu@arcmenu.com"
  local ARC_DIR="/usr/share/gnome-shell/extensions/$ARC_UUID"

  if [ ! -d "$ARC_DIR" ]; then
    info "Installing ArcMenu from GNOME Extensions…"
    if command -v curl >/dev/null 2>&1; then
      curl -L --fail -o "./Linux/arcmenu.zip" "$ARC_URL"
    else
      wget -O "./Linux/arcmenu.zip" "$ARC_URL"
    fi
    sudo mkdir -p "$ARC_DIR"
    sudo unzip -qq -o "./Linux/arcmenu.zip" -d "$ARC_DIR"
    sudo chmod 0644 /usr/share/gnome-shell/extensions/arcmenu@arcmenu.com/metadata.json
    sudo find  /usr/share/gnome-shell/extensions/arcmenu@arcmenu.com -type f -exec chmod a+r  {} \;
    sudo find  /usr/share/gnome-shell/extensions/arcmenu@arcmenu.com -type d -exec chmod a+rx {} \;
    ok "ArcMenu installed to $ARC_DIR."
  else
    ok "ArcMenu already present at $ARC_DIR."
  fi

  # Try to enable the extensions if GNOME + gsettings are available
  if command -v gsettings >/dev/null 2>&1; then
    info "Attempting to enable extensions… (safe to ignore if this is a TTY-only session)"

    declare -a WANT_UUIDS=(
      "dash-to-panel@jderose9.github.com"
      "user-theme@gnome-shell-extensions.gcampax.github.com"
      "blur-my-shell@aunetx"
      "arcmenu@arcmenu.com"
      "ding@rastersoft.com"   # Desktop Icons NG
      "light-style@gnome-shell-extensions.gcampax.github.com"
    )

    local SCHEMA="org.gnome.shell"
    local KEY="enabled-extensions"
    local CUR
    CUR="$(gsettings get "$SCHEMA" "$KEY" | sed "s/^@as //")"

    add_uuid() {
      local uuid="$1"
      if [ -d "$HOME/.local/share/gnome-shell/extensions/$uuid" ] || \
         [ -d "/usr/share/gnome-shell/extensions/$uuid" ]; then
        [[ "$CUR" == *"$uuid"* ]] || {
          CUR=$([[ "$CUR" == "[]" ]] && echo "['$uuid']" || echo "$(echo "$CUR" | sed "s/]$/, '$uuid']/")")
        }
      fi
    }

    for u in "${WANT_UUIDS[@]}"; do add_uuid "$u"; done
    gsettings set "$SCHEMA" "$KEY" "$CUR" || true
    ok "Extensions enabled (where available)."
    gsettings set org.gnome.mutter experimental-features "[]"
    info "Tip: Use Extension Manager and GNOME Tweaks to customise behaviour."
  else
    warn "gsettings not available; skipping auto-enable. Extensions are installed."
  fi

  # Offer to log off so GNOME restarts and loads the extensions/theme cleanly
  echo
  read -r -p 'Log off now to apply changes? [y/N]: ' ans
  case "${ans,,}" in
    y|yes)
      info "Logging off current session…"
      # Prefer GNOME’s session helper if present
      if command -v gnome-session-quit >/dev/null 2>&1; then
        exec gnome-session-quit --logout --no-prompt
      elif [[ -n "${XDG_SESSION_ID:-}" ]] && command -v loginctl >/dev/null 2>&1; then
        exec loginctl terminate-session "$XDG_SESSION_ID"
      else
        warn "Could not determine a safe logout method automatically."
        warn "Please log out manually from the system menu."
      fi
      ;;
    *) info "OK, not logging off now. Changes will apply next time you log in.";;
  esac
}

# ──────────────────────────────────────────────────────────────────────────────
# [12/12] APPLY CUSTOM GNOME SETTINGS
#   • Import ArcMenu + Dash-to-Panel from their own .dconf files (scoped)
#   • Apply GNOME tweaks via gsettings (explicit list; no file parsing)
# ──────────────────────────────────────────────────────────────────────────────
step_apply_custom_gnome_settings() {
  info "[12/12] Applying custom GNOME settings…"

  # Resolve script directory (handles symlinks & spaces)
  local script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

  # Expected inputs for the two extensions
  local ARC_FILE="$script_dir/Linux/ArcMenu.dconf"
  local DTP_FILE="$script_dir/Linux/Dash-to-Panel.dconf"

  # --- Import ArcMenu and Dash-to-Panel first (prefix-scoped)
  if command -v dconf >/dev/null 2>&1; then
    if [[ -f "$ARC_FILE" ]]; then
      info "Importing ArcMenu → /org/gnome/shell/extensions/arcmenu/ …"
      dconf load /org/gnome/shell/extensions/arcmenu/ < "$ARC_FILE" || warn "ArcMenu import failed (continuing)."
    else
      warn "ArcMenu file not found: $ARC_FILE"
    fi
    if [[ -f "$DTP_FILE" ]]; then
      info "Importing Dash-to-Panel → /org/gnome/shell/extensions/dash-to-panel/ …"
      dconf load /org/gnome/shell/extensions/dash-to-panel/ < "$DTP_FILE" || warn "Dash-to-Panel import failed (continuing)."
    else
      warn "Dash-to-Panel file not found: $DTP_FILE"
    fi
  else
    warn "dconf not available; skipping ArcMenu/Dash-to-Panel imports."
  fi

  # --- Apply remaining GNOME settings *explicitly* via gsettings
  need_cmd gsettings || { err "gsettings not available; cannot apply GNOME tweaks."; return 1; }

  info "Applying GNOME tweaks via gsettings (non-ArcMenu / non-Dash-to-Panel)…"

  # Interface fonts & cursor
  gsettings set org.gnome.desktop.interface cursor-theme 'Breeze_Light' || warn "cursor-theme failed"
  gsettings set org.gnome.desktop.interface document-font-name 'Aptos 12' || warn "document-font-name failed"
  gsettings set org.gnome.desktop.interface font-name 'Segoe UI Variable 11 @opsz=11' || warn "font-name failed"
  gsettings set org.gnome.desktop.interface monospace-font-name 'Consolas 11' || warn "monospace-font-name failed"

  # Optional: set DM/TTY cursor theme system-wide to match
  if command -v update-alternatives >/dev/null 2>&1 && [ -f /usr/share/icons/Breeze_Light/cursor.theme ]; then
    sudo update-alternatives --set x-cursor-theme /usr/share/icons/Breeze_Light/cursor.theme || true
  fi

  # Window manager button layout
  gsettings set org.gnome.desktop.wm.preferences button-layout 'appmenu:minimize,maximize,close' || warn "button-layout failed"

  # Nautilus (Files)
  gsettings set org.gnome.nautilus.icon-view default-zoom-level 'small' || warn "nautilus icon-view zoom failed"
  gsettings set org.gnome.nautilus.preferences show-create-link true || warn "show-create-link failed"

  # Desktop Icons NG (DING)
  gsettings set org.gnome.shell.extensions.ding icon-size 'small' || warn "ding icon-size failed"

  # GTK3
  gsettings set org.gtk.Settings.FileChooser show-hidden true || warn "gtk4 file-chooser show-hidden failed"
  gsettings set org.gtk.Settings.FileChooser sort-directories-first true || warn "gtk4 file-chooser sort-directories-first failed"

  # GTK4
  gsettings set org.gtk.gtk4.Settings.FileChooser show-hidden true || warn "gtk3 file-chooser show-hidden failed"
  gsettings set org.gtk.gtk4.Settings.FileChooser sort-directories-first true || warn "gtk3 file-chooser sort-directories-first failed"

  ok "GNOME settings applied via gsettings."
}

# ──────────────────────────────────────────────────────────────────────────────
# Menu / Router
# ──────────────────────────────────────────────────────────────────────────────
print_menu() {
  cat <<'MENU'
Post-install helper — choose an option:

  1) Add user to passwordless sudo            [1/12]
  2) GNOME Terminal shortcut (Ctrl+Alt+T)     [2/12]
  3) GNOME Terminal white on black            [3/12]
  4) Update Debian sources (Deb822)           [4/12]
  5) Install handy apps                       [5/12]
  6) Crypt GUI (Plymouth + GRUB tweaks)       [6/12]
  7) Import Windows fonts to system           [7/12]
  8) Install wallpapers + set background      [8/12]
  9) Install Win11 icon theme (system)        [9/12]
 10) Set user profile photo                   [10/12]
 11) GNOME extensions + Manager + Tweaks      [11/12]
 12) Apply custom GNOME settings (dconf)      [12/12]
  a) Run ALL steps in order
  q) Quit
MENU
}

run_choice() {
  case "$1" in
    1) step_sudo_nopass ;;
    2) step_gnome_shortcut ;;
    3) step_gnome_terminal_theme ;;
    4) step_sources ;;
    5) step_apps ;;
    6) step_crypt_gui ;;
    7) step_import_windows_fonts ;;
    8) step_install_wallpapers ;;
    9) step_install_icon_theme ;;
    10) step_set_profile_photo ;;
    11) step_gnome_extensions ;;
    12) step_apply_custom_gnome_settings ;;
    a|A)
      step_sudo_nopass
      step_gnome_shortcut
      step_gnome_terminal_theme
      step_sources
      step_apps
      step_crypt_gui
      step_import_windows_fonts
      step_install_wallpapers
      step_install_icon_theme
      step_set_profile_photo
      step_gnome_extensions
      step_apply_custom_gnome_settings
      ;;
    q|Q) exit 0 ;;
    *) err "Unknown choice: $1"; return 1 ;;
  esac
}

# Allow quick-jump via args, e.g. ./postinstall.sh 4 6
if (( $# )); then
  for c in "$@"; do run_choice "$c"; done
  exit 0
fi

# Interactive loop
while true; do
  print_menu
  read -rp "Select: " choice || exit 0
  run_choice "$choice" || true
  echo
  ask_yn "Do you want to choose another option?" y || break
done

info "All done. You can re-run this script any time; steps are idempotent."

