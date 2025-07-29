#!/bin/bash

set -euo pipefail

# Configuration
ISO_NAME="bootc-live.iso"
WORK_DIR="$HOME/live-iso-build"
ISO_LABEL="LiveCD"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    error "Don't run this script as root. It will use sudo when needed."
fi

# Check dependencies
check_deps() {
    local deps=("squashfs-tools" "genisoimage" "syslinux")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! rpm -q "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing[*]}. Install with: sudo dnf install ${missing[*]}"
    fi
}

# Clean up function
cleanup() {
    log "Cleaning up temporary files..."
    sudo rm -f /tmp/filesystem.squashfs 2>/dev/null || true
}

# Set up trap for cleanup
trap cleanup EXIT

main() {
    log "Starting bootc to live ISO creation..."
    
    # Check dependencies
    check_deps
    
    # Clean up any previous build
    if [[ -d "$WORK_DIR" ]]; then
        warn "Removing previous build directory: $WORK_DIR"
        rm -rf "$WORK_DIR"
    fi
    
    # Create ISO structure
    log "Creating ISO directory structure..."
    mkdir -p "$WORK_DIR"/{LiveOS,isolinux,EFI/BOOT}
    
    # Create squashfs
    log "Creating SquashFS filesystem (this may take a while)..."
    sudo mksquashfs / /tmp/filesystem.squashfs \
        -comp xz -Xbcj x86 \
        -e boot dev proc sys tmp run var/tmp var/log var/cache \
           mnt media lost+found home/*/.cache \
        -wildcards \
        -progress
    
    # Move squashfs to ISO structure
    log "Moving SquashFS to ISO structure..."
    sudo mv /tmp/filesystem.squashfs "$WORK_DIR/LiveOS/squashfs.img"
    sudo chown $USER:$USER "$WORK_DIR/LiveOS/squashfs.img"
    
    # Copy boot files
    log "Copying boot files..."
    
    # Find kernel - check ostree path first, then standard path
    local kernel_path=""
    local initramfs_path=""
    
    # Method 1: Try to find kernel in ostree path using find
    kernel_path=$(find /boot/ostree -name "vmlinuz-$(uname -r)" 2>/dev/null | head -1)
    initramfs_path=$(find /boot/ostree -name "initramfs-$(uname -r).img" 2>/dev/null | head -1)
    
    # Method 2: If not found, try using bootc status to find current deployment
    if [[ -z "$kernel_path" ]] && command -v bootc &>/dev/null; then
        log "Trying to find kernel using bootc deployment info..."
        local deployment_id
        deployment_id=$(bootc status --json 2>/dev/null | jq -r '.status.booted.image.imageDigest' 2>/dev/null | cut -d: -f2 | head -c12)
        if [[ -n "$deployment_id" ]]; then
            for dir in /boot/ostree/fedora-*; do
                if [[ -f "$dir/vmlinuz-$(uname -r)" ]]; then
                    kernel_path="$dir/vmlinuz-$(uname -r)"
                    initramfs_path="$dir/initramfs-$(uname -r).img"
                    break
                fi
            done
        fi
    fi
    
    # Method 3: Fall back to standard boot path if not found in ostree
    if [[ -z "$kernel_path" && -f "/boot/vmlinuz-$(uname -r)" ]]; then
        kernel_path="/boot/vmlinuz-$(uname -r)"
        initramfs_path="/boot/initramfs-$(uname -r).img"
    fi
    
    # Check if we found the files
    if [[ -z "$kernel_path" || ! -f "$kernel_path" ]]; then
        error "Kernel not found. Checked /boot/ostree/ and /boot/ paths."
    fi
    
    if [[ -z "$kernel_path" || ! -f "$kernel_path" ]]; then
        error "Kernel file not found"
    fi
    
    if [[ -z "$initramfs_path" || ! -f "$initramfs_path" ]]; then
        error "Initramfs file not found"
    fi
    
    log "Found kernel: $kernel_path"
    log "Found initramfs: $initramfs_path"
    
    sudo cp "$kernel_path" "$WORK_DIR/isolinux/vmlinuz"
    sudo cp "$initramfs_path" "$WORK_DIR/isolinux/initramfs.img"
    sudo chown $USER:$USER "$WORK_DIR/isolinux/"*
    
    # Copy EFI files if they exist
    if [[ -d "/boot/efi/EFI" ]]; then
        log "Copying EFI boot files..."
        sudo cp -r /boot/efi/EFI/* "$WORK_DIR/EFI/" 2>/dev/null || true
        sudo chown -R $USER:$USER "$WORK_DIR/EFI/" 2>/dev/null || true
    fi
    
    # Create isolinux configuration
    log "Creating boot configuration..."
    cat > "$WORK_DIR/isolinux/isolinux.cfg" << 'EOF'
default vesamenu.c32
timeout 100
prompt 0

menu title Live Boot Menu
menu background splash.png

label live
  menu label ^Start Live System
  menu default
  kernel vmlinuz
  append initrd=initramfs.img root=live:CDLABEL=LiveCD rd.live.image quiet splash

label live-basic
  menu label Start Live System (^Basic Graphics)
  kernel vmlinuz
  append initrd=initramfs.img root=live:CDLABEL=LiveCD rd.live.image nomodeset quiet

label memory-test
  menu label ^Memory Test
  kernel memtest
EOF
    
    # Copy isolinux files
    log "Copying bootloader files..."
    local syslinux_files=("isolinux.bin" "vesamenu.c32" "ldlinux.c32" "libcom32.c32" "libutil.c32")
    
    for file in "${syslinux_files[@]}"; do
        if [[ -f "/usr/share/syslinux/$file" ]]; then
            cp "/usr/share/syslinux/$file" "$WORK_DIR/isolinux/"
        else
            warn "Syslinux file $file not found, skipping..."
        fi
    done
    
    # Create .discinfo file
    echo "$(date +%s)" > "$WORK_DIR/.discinfo"
    
    # Generate the ISO
    log "Generating ISO image..."
    local genisoimage_args=(
        -V "$ISO_LABEL"
        -J -r -hide-rr-moved
        -b isolinux/isolinux.bin
        -c isolinux/boot.cat
        -no-emul-boot
        -boot-load-size 4
        -boot-info-table
    )
    
    # Add UEFI boot if EFI files exist
    if [[ -f "$WORK_DIR/EFI/BOOT/bootx64.efi" ]]; then
        log "Adding UEFI boot support..."
        genisoimage_args+=(
            -eltorito-alt-boot
            -e EFI/BOOT/bootx64.efi
            -no-emul-boot
        )
    fi
    
    genisoimage_args+=(
        -o "$HOME/$ISO_NAME"
        "$WORK_DIR"
    )
    
    sudo genisoimage "${genisoimage_args[@]}"
    
    # Make it hybrid bootable
    if command -v isohybrid &>/dev/null; then
        log "Making ISO hybrid bootable..."
        if [[ -f "$WORK_DIR/EFI/BOOT/bootx64.efi" ]]; then
            sudo isohybrid --uefi "$HOME/$ISO_NAME"
        else
            sudo isohybrid "$HOME/$ISO_NAME"
        fi
    else
        warn "isohybrid not found, ISO may not be USB bootable"
    fi
    
    # Fix ownership
    sudo chown $USER:$USER "$HOME/$ISO_NAME"
    
    # Show results
    local iso_size=$(du -h "$HOME/$ISO_NAME" | cut -f1)
    success "Live ISO created successfully!"
    echo
    echo "📀 ISO file: $HOME/$ISO_NAME"
    echo "📏 Size: $iso_size"
    echo
    echo "You can now:"
    echo "  • Test in a VM: qemu-system-x86_64 -cdrom $HOME/$ISO_NAME -m 2G"
    echo "  • Write to USB: sudo dd if=$HOME/$ISO_NAME of=/dev/sdX bs=4M status=progress"
    echo "  • Burn to DVD using your preferred burning software"
    
    # Clean up build directory
    log "Cleaning up build directory..."
    rm -rf "$WORK_DIR"
}

# Show usage if help requested
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: $0"
    echo
    echo "This script creates a live bootable ISO from your current bootc system."
    echo "It will create '$ISO_NAME' in your home directory."
    echo
    echo "Requirements:"
    echo "  - squashfs-tools"
    echo "  - genisoimage" 
    echo "  - syslinux"
    echo
    echo "Install with: sudo dnf install squashfs-tools genisoimage syslinux"
    exit 0
fi

main "$@"