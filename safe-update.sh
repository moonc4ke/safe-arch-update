#!/bin/bash

# safe-update.sh - Safe Arch Linux update script with kernel handling
# Makes sure kernel updates are properly installed and configured

# Don't exit on error - we want to handle errors ourselves
# set -e is removed

# Define colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to print status messages
status() {
  echo -e "${GREEN}[*] $1${NC}"
}

# Function to print warning messages
warning() {
  echo -e "${YELLOW}[!] $1${NC}"
}

# Function to print error messages
error() {
  echo -e "${RED}[ERROR] $1${NC}" >&2
}

# Function to maintain GDM login screen background after updates
maintain_login_background() {
  status "Ensuring GDM login screen background is preserved..."
  
  # Check if GDM is the display manager
  if [ -e "/etc/systemd/system/display-manager.service" ] && 
     grep -q "gdm" "/etc/systemd/system/display-manager.service"; then
    
    # Check if gdm-tools is installed
    if command -v set-gdm-theme &>/dev/null; then
      status "Reapplying GDM theme settings using gdm-tools..."
      
      # First, update the backup to ensure we have the current theme
      set-gdm-theme -b update || warning "Failed to update GDM theme backup"
      
      # Then try to restore from backup to refresh the theme
      set-gdm-theme -b restore || warning "Failed to restore GDM theme from backup"
    else
      # Use dconf directly
      if [ -e "/etc/dconf/db/gdm.d" ]; then
        status "Refreshing GDM dconf database..."
        dconf update || warning "Failed to update dconf database"
      fi
    fi
    
    # Force GDM configuration reload if running
    if systemctl is-active gdm.service &>/dev/null; then
      status "Requesting GDM to reload settings..."
      systemctl reload gdm.service &>/dev/null || true
    fi
    
    # Set proper permissions on common background directories
    local BG_DIRS=(
      "/usr/share/backgrounds"
      "/usr/share/gnome-background-properties"
      "/usr/share/gnome/backgrounds"
      "/usr/share/wallpapers"
      "/var/lib/gdm/.local/share/backgrounds"
    )
    
    for DIR in "${BG_DIRS[@]}"; do
      if [ -d "$DIR" ]; then
        status "Ensuring proper permissions on background directory: $DIR"
        chmod -R a+r "$DIR" 2>/dev/null || warning "Failed to set permissions on $DIR"
      fi
    done
    
    # Check if the GDM user exists and fix its permissions
    if id "gdm" &>/dev/null; then
      # Make sure GDM user can access the background images
      status "Ensuring GDM user can access backgrounds..."
      for DIR in "${BG_DIRS[@]}"; do
        if [ -d "$DIR" ]; then
          # Add execute permission to directories for GDM user
          find "$DIR" -type d -exec chmod a+x {} \; 2>/dev/null || true
        fi
      done
    fi
    
    status "GDM background preservation complete"
  else
    warning "GDM display manager not detected. Login background might not be preserved."
  fi
}

# Function to check if running as root
check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    return 1
  fi
}

# Check for Arch news before updating
check_arch_news() {
  status "Checking for important Arch news..."

  # Get the actual user (not root)
  ACTUAL_USER=$(logname 2>/dev/null || echo $SUDO_USER)

  if command -v yay &>/dev/null; then
    # Run yay as the actual user, not root
    sudo -u "$ACTUAL_USER" yay -Pw
  else
    warning "yay not found, skipping news check. Consider installing yay for better updates."
  fi

  echo ""
  read -p "Continue with update? (y/n): " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    status "Update cancelled."
    return 0
  fi
}

# Check for required utilities and install if missing
check_dependencies() {
  status "Checking for required utilities..."

  # Check for paccache (from pacman-contrib)
  if ! command -v paccache &>/dev/null; then
    status "Installing pacman-contrib for paccache utility..."
    pacman -S --noconfirm pacman-contrib
  fi
}

# Check and clean boot directory if low on space
check_boot_space() {
  status "Checking boot partition space..."

  # Get boot partition and available space
  BOOT_PARTITION=$(df -h /boot | grep -v Filesystem | awk '{print $1}')
  BOOT_AVAIL=$(df -m /boot | grep -v Filesystem | awk '{print $4}')

  status "Boot partition ($BOOT_PARTITION) has ${BOOT_AVAIL}MB available"

  # Remove any existing backup directories
  if ls -dt /boot/backup-* &>/dev/null; then
    status "Removing all kernel backup directories..."
    rm -rf /boot/backup-*
  fi

  # If less than 75MB available, perform cleanup
  if [ "$BOOT_AVAIL" -lt 75 ]; then
    warning "Low space on boot partition. Performing cleanup..."

    # Check for any large unnecessary files - DO NOT include K6604JIAS.302
    status "Checking for other large files in /boot..."
    LARGE_FILES=$(find /boot -type f -size +10M \
      -not -name "vmlinuz-*" \
      -not -name "initramfs-*.img" \
      -not -name "K6604JIAS.302" |
      grep -v "grub" |
      grep -v "EFI")

    if [ -n "$LARGE_FILES" ]; then
      warning "Found large files that may be removed to free space:"
      echo "$LARGE_FILES"
      echo ""
      read -p "Remove these files? (y/n): " -n 1 -r
      echo ""
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "$LARGE_FILES" | xargs -r rm -f
        status "Large files removed"
      fi
    fi

    # FIXED: More careful cleanup that preserves current kernels
    # First, create a safe list of files we should NEVER delete
    SAFE_KERNELS=""

    # Add all installed kernels to safe list
    for KERNEL in $(pacman -Q linux linux-lts linux-zen linux-hardened 2>/dev/null | awk '{print $1}'); do
      if [[ "$KERNEL" == "linux" ]]; then
        SAFE_KERNELS="$SAFE_KERNELS vmlinuz-linux initramfs-linux.img"
      elif [[ "$KERNEL" == "linux-lts" ]]; then
        SAFE_KERNELS="$SAFE_KERNELS vmlinuz-linux-lts initramfs-linux-lts.img"
      elif [[ "$KERNEL" == "linux-zen" ]]; then
        SAFE_KERNELS="$SAFE_KERNELS vmlinuz-linux-zen initramfs-linux-zen.img"
      elif [[ "$KERNEL" == "linux-hardened" ]]; then
        SAFE_KERNELS="$SAFE_KERNELS vmlinuz-linux-hardened initramfs-linux-hardened.img"
      fi
    done

    status "Preserving essential kernel files: $SAFE_KERNELS"

    # Delete old files ONLY if they're not in our safe list
    find /boot -type f -name "vmlinuz-*" -o -name "initramfs-*.img" | while read -r FILE; do
      FILENAME=$(basename "$FILE")
      if ! echo "$SAFE_KERNELS" | grep -q "$FILENAME"; then
        status "Removing old kernel file: $FILE"
        rm -f "$FILE"
      else
        status "Preserving current kernel file: $FILE"
      fi
    done

    BOOT_AVAIL_AFTER=$(df -m /boot | grep -v Filesystem | awk '{print $4}')
    status "After cleanup: Boot partition has ${BOOT_AVAIL_AFTER}MB available"

    # If still below 25MB, show warning
    if [ "$BOOT_AVAIL_AFTER" -lt 25 ]; then
      error "CRITICAL: Boot partition still low on space after cleanup!"
      warning "Consider increasing the size of your boot partition"
      warning "or removing some non-essential files manually."
    fi
  fi
}

# Check if kernel files exist and reinstall if missing
check_kernel_files() {
  status "Checking if kernel files exist..."

  # Get installed kernels - use temp file to avoid pipeline issues
  pacman -Q linux linux-lts linux-zen linux-hardened 2>/dev/null >/tmp/installed_kernels.txt

  if [ ! -s /tmp/installed_kernels.txt ]; then
    warning "No kernel packages found. Installing the standard linux kernel..."
    pacman -S --noconfirm linux
    return 0
  fi

  # Process each installed kernel
  KERNEL_MISSING=false

  while read -r KERNEL_PKG; do
    if [ -n "$KERNEL_PKG" ]; then
      KERNEL_NAME=$(echo "$KERNEL_PKG" | awk '{print $1}')

      # Determine correct kernel filename
      if [[ "$KERNEL_NAME" == "linux" ]]; then
        KERNEL_FILE="/boot/vmlinuz-linux"
      elif [[ "$KERNEL_NAME" == "linux-lts" ]]; then
        KERNEL_FILE="/boot/vmlinuz-linux-lts"
      elif [[ "$KERNEL_NAME" == "linux-zen" ]]; then
        KERNEL_FILE="/boot/vmlinuz-linux-zen"
      elif [[ "$KERNEL_NAME" == "linux-hardened" ]]; then
        KERNEL_FILE="/boot/vmlinuz-linux-hardened"
      else
        KERNEL_FILE="/boot/vmlinuz-${KERNEL_NAME}"
      fi

      status "Checking kernel file: $KERNEL_FILE for package $KERNEL_NAME"

      if [ ! -f "$KERNEL_FILE" ]; then
        warning "Kernel file $KERNEL_FILE is missing for package $KERNEL_NAME"
        status "Reinstalling $KERNEL_NAME to restore kernel files..."
        pacman -S --noconfirm "$KERNEL_NAME"
        KERNEL_MISSING=true
      else
        status "Kernel file $KERNEL_FILE exists for package $KERNEL_NAME"
      fi
    fi
  done </tmp/installed_kernels.txt

  # Clean up
  rm -f /tmp/installed_kernels.txt

  # If we reinstalled any kernels, make sure they're properly configured
  if [ "$KERNEL_MISSING" = true ]; then
    status "Kernel files were missing and reinstalled. Running additional configuration..."

    # Additional checks to verify kernel files were actually created
    if ! ls /boot/vmlinuz-* &>/dev/null; then
      error "Kernel files still missing after reinstall! Your /boot partition may have issues."
      status "Manually installing linux kernel with special options..."

      # Try installing with extra options to force kernel files installation
      pacman -S --noconfirm --overwrite '*' linux
    fi
  fi
}

# Check GNOME version and ask if user wants to update
check_gnome_update() {
  # Check if GNOME is installed
  if pacman -Q gnome-shell &>/dev/null; then
    status "Checking GNOME Desktop Environment version..."
    
    # Get current installed version
    CURRENT_GNOME=$(pacman -Q gnome-shell | awk '{print $2}')
    
    # Get latest available version - fix to make it more reliable
    pacman -Sy >/dev/null 2>&1  # Refresh package database silently
    LATEST_GNOME=$(pacman -Si gnome-shell | grep Version | awk '{print $3}')
    
    status "Current GNOME version: $CURRENT_GNOME"
    status "Latest GNOME version available: $LATEST_GNOME"
    
    # Compare versions (simple string comparison, could be improved)
    if [ "$CURRENT_GNOME" != "$LATEST_GNOME" ]; then
      echo ""
      read -p "Update GNOME to latest version? (y/N): " -n 1 -r
      echo ""
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        status "Will update GNOME to latest version during system update..."
        # Set flag to not skip GNOME updates
        export SKIP_GNOME_UPDATE=false
      else
        status "GNOME will NOT be updated to the latest version..."
        # Set flag to skip GNOME updates
        export SKIP_GNOME_UPDATE=true
      fi
    else
      status "GNOME is already at the latest version"
      export SKIP_GNOME_UPDATE=false
    fi
  else
    # GNOME not installed
    status "GNOME Desktop Environment not detected on this system"
    export SKIP_GNOME_UPDATE=false
  fi
}

# Perform the actual system update
perform_update() {
  status "Updating pacman databases..."
  pacman -Sy

  status "Performing full system update..."

  # Get the actual user (not root)
  ACTUAL_USER=$(logname 2>/dev/null || echo $SUDO_USER)

  # Prepare ignore packages list if needed
  IGNORE_OPTS=""
  if [ "$SKIP_GNOME_UPDATE" = true ]; then
    status "Excluding GNOME packages from update..."
    IGNORE_OPTS="--ignore gnome-shell,gnome-session,gnome-settings-daemon,gnome-control-center,mutter"
  fi

  if command -v yay &>/dev/null; then
    # Use yay if available for AUR packages
    status "Using yay for system update (running as $ACTUAL_USER)"
    if [ -n "$IGNORE_OPTS" ]; then
      sudo -u "$ACTUAL_USER" yay -Syu --noconfirm $IGNORE_OPTS || {
        warning "yay update failed! Falling back to pacman..."
        pacman -Syu --noconfirm $IGNORE_OPTS || error "pacman update failed!"
      }
    else
      sudo -u "$ACTUAL_USER" yay -Syu --noconfirm || {
        warning "yay update failed! Falling back to pacman..."
        pacman -Syu --noconfirm || error "pacman update failed!"
      }
    fi
  else
    # Fall back to just pacman
    if [ -n "$IGNORE_OPTS" ]; then
      pacman -Syu --noconfirm $IGNORE_OPTS || error "pacman update failed!"
    else
      pacman -Syu --noconfirm || error "pacman update failed!"
    fi
  fi
}

# Check if the kernel was updated
check_kernel_update() {
  status "Checking for kernel updates..."

  # Get list of updated packages
  UPDATED_PKGS=$(grep " upgraded the following packages:" /var/log/pacman.log | tail -n1 | cut -d: -f2)

  # Check if linux or linux-lts or any other kernel was updated
  if echo "$UPDATED_PKGS" | grep -q "linux"; then
    status "Kernel update detected"
    return 0
  else
    status "No kernel update detected"
    return 1
  fi
}

# Rebuild initramfs
rebuild_initramfs() {
  status "Rebuilding initramfs for all kernels..."

  # Check if any kernel files exist before attempting to rebuild
  if ! ls /boot/vmlinuz-* &>/dev/null; then
    warning "No kernel files found in /boot. Cannot rebuild initramfs."
    warning "Try reinstalling your kernel package with: sudo pacman -S linux"
    return 1
  fi

  mkinitcpio -P || {
    warning "Failed to rebuild all initramfs images. Trying individual kernels..."

    # Try rebuilding for each kernel individually
    for KERNEL_FILE in /boot/vmlinuz-*; do
      if [ -f "$KERNEL_FILE" ]; then
        KERNEL_VERSION=$(basename "$KERNEL_FILE" | sed 's/vmlinuz-//')
        status "Rebuilding initramfs for kernel $KERNEL_VERSION"
        mkinitcpio -p "$KERNEL_VERSION" || warning "Failed to rebuild initramfs for $KERNEL_VERSION"
      fi
    done
  }
}

# Update GRUB config
update_grub() {
  status "Updating GRUB configuration..."
  if [ -f /boot/grub/grub.cfg ]; then
    grub-mkconfig -o /boot/grub/grub.cfg || error "Failed to update GRUB config!"
  elif [ -f /boot/efi/EFI/arch/grub.cfg ]; then
    grub-mkconfig -o /boot/efi/EFI/arch/grub.cfg || error "Failed to update GRUB config!"
  else
    warning "GRUB config not found at standard locations"
    # Try to find and update it
    GRUB_CONFIG=$(find /boot -name "grub.cfg" 2>/dev/null | head -n1)
    if [ -n "$GRUB_CONFIG" ]; then
      grub-mkconfig -o "$GRUB_CONFIG" || error "Failed to update GRUB config at $GRUB_CONFIG!"
    else
      error "Could not find GRUB config file. You may need to update it manually."
    fi
  fi
}

# Verify the boot entries
verify_boot_entries() {
  status "Verifying boot entries..."

  if [ -d /boot/loader/entries ]; then
    # systemd-boot is being used
    status "systemd-boot detected, checking entries..."
    if ls /boot/loader/entries/*.conf &>/dev/null; then
      status "Boot entries found"
    else
      warning "No boot entries found for systemd-boot"
    fi
  elif [ -f /boot/grub/grub.cfg ]; then
    # GRUB is being used
    status "GRUB detected, checking config..."
    if grep -q "menuentry" /boot/grub/grub.cfg; then
      status "GRUB entries found"
    else
      warning "No menu entries found in GRUB config"
    fi
  else
    warning "Unable to determine bootloader type"
  fi
}

# Cleanup old packages, keep the newest and one previous version
cleanup_packages() {
  status "Cleaning package cache (keeping the most recent versions)..."
  if command -v paccache &>/dev/null; then
    paccache -rk1
  else
    warning "paccache not found, skipping package cache cleanup"
  fi
}

# Main function
main() {
  # Initialize exit code
  SCRIPT_EXIT_CODE=0

  # Start with basic checks
  check_root || exit 1
  check_dependencies || warning "Some dependencies might be missing"

  # Run boot space check to clean up boot partition
  check_boot_space || warning "Boot space check failed but continuing"

  check_arch_news || warning "Arch news check failed but continuing"

  # Check GNOME version before updating
  check_gnome_update || warning "GNOME version check failed but continuing"

  # Update system
  perform_update || {
    warning "System update had issues, but we'll continue with kernel checks"
    SCRIPT_EXIT_CODE=1
  }

  # This is the most important part - check and fix kernel files
  status "Checking and fixing kernel files..."
  check_kernel_files || {
    warning "Kernel file check failed"
    SCRIPT_EXIT_CODE=1
  }

  # Force a reinstall of the kernel if files are still missing
  if ! ls /boot/vmlinuz-* &>/dev/null; then
    warning "Kernel files still missing! Forcing reinstall of linux kernel..."
    pacman -S --noconfirm --overwrite '*' linux
  fi

  # Rebuild initramfs with protection against failure
  rebuild_initramfs || {
    warning "Initramfs rebuild had issues but continuing"
    SCRIPT_EXIT_CODE=1
  }

  # Update bootloader
  update_grub || {
    warning "GRUB update had issues but continuing"
    SCRIPT_EXIT_CODE=1
  }

  # Preserve login screen background
  maintain_login_background || {
    warning "Login background preservation had issues but continuing"
    SCRIPT_EXIT_CODE=1
  }

  # Final checks
  verify_boot_entries || warning "Boot entry verification failed but continuing"
  cleanup_packages || warning "Package cleanup failed but continuing"

  # Final system check
  if ls /boot/vmlinuz-* &>/dev/null && ls /boot/initramfs-*.img &>/dev/null; then
    status "Kernel files and initramfs are now present in /boot"
  else
    error "CRITICAL: Kernel files or initramfs still missing after all recovery attempts!"
    error "Your system may not boot properly. Please address this manually."
    SCRIPT_EXIT_CODE=2
  fi

  if [ $SCRIPT_EXIT_CODE -eq 0 ]; then
    status "Safe update completed successfully!"
  else
    warning "Safe update completed with some issues (exit code: $SCRIPT_EXIT_CODE)"
  fi

  status "It's recommended to reboot your system to use the updated kernel and modules."
  read -p "Reboot now? (y/n): " -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    status "Rebooting..."
    systemctl reboot
  else
    status "Please remember to reboot soon to complete the update process."
  fi

  exit $SCRIPT_EXIT_CODE
}

# Execute main function
main
