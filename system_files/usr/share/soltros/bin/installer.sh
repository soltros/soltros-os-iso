#!/usr/bin/env bash

set -euo pipefail

# Check for required tools
command -v bootc >/dev/null || { echo "bootc is not installed. Exiting."; exit 1; }

echo "Welcome to the SoltrOS Installer"
echo "--------------------------------"
echo "This script will install SoltrOS using bootc and help set up a user account."

# Select target device
read -rp "Enter the target device (e.g., /dev/sda): " TARGET_DISK
if [[ ! -b "$TARGET_DISK" ]]; then
    echo "Error: $TARGET_DISK is not a valid block device."
    exit 1
fi

# Confirm with the user
echo "WARNING: All data on $TARGET_DISK will be erased!"
read -rp "Are you sure you want to continue? (yes/[no]): " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "Aborting."
    exit 1
fi

# Get username
read -rp "Enter new username: " NEWUSER
if [[ -z "$NEWUSER" ]]; then
    echo "Username cannot be empty."
    exit 1
fi

# Set password (hashed for use with useradd later)
read -rsp "Enter password for $NEWUSER: " PASSWORD
echo
read -rsp "Confirm password: " PASSWORD_CONFIRM
echo

if [[ "$PASSWORD" != "$PASSWORD_CONFIRM" ]]; then
    echo "Passwords do not match."
    exit 1
fi

# Optional hostname
read -rp "Enter hostname for the installed system (default: soltros): " HOSTNAME
HOSTNAME=${HOSTNAME:-soltros}

# Optional SSH public key
read -rp "Enter path to your SSH public key (or leave blank to skip): " SSH_KEY_PATH
if [[ -n "$SSH_KEY_PATH" && ! -f "$SSH_KEY_PATH" ]]; then
    echo "SSH key file not found: $SSH_KEY_PATH"
    exit 1
fi

# Run bootc install
echo "Installing SoltrOS to $TARGET_DISK..."
bootc install --root-device "$TARGET_DISK"

# Mount the new root to configure it
mount "${TARGET_DISK}3" /mnt || mount "${TARGET_DISK}"p3 /mnt || {
    echo "Failed to mount new root partition. Please check the partition layout."
    exit 1
}

# Create user in target system
echo "Creating user $NEWUSER..."

chroot /mnt useradd -m -G wheel -s /bin/bash "$NEWUSER"
echo "$NEWUSER:$PASSWORD" | chroot /mnt chpasswd

# Set hostname
echo "$HOSTNAME" > /mnt/etc/hostname

# Set up sudoers (assumes sudo is installed)
if ! grep -q "^%wheel" /mnt/etc/sudoers; then
    echo "%wheel ALL=(ALL) NOPASSWD: ALL" >> /mnt/etc/sudoers
fi

# Copy SSH key if provided
if [[ -n "$SSH_KEY_PATH" ]]; then
    mkdir -p /mnt/home/"$NEWUSER"/.ssh
    cp "$SSH_KEY_PATH" /mnt/home/"$NEWUSER"/.ssh/authorized_keys
    chroot /mnt chown -R "$NEWUSER:$NEWUSER" /home/"$NEWUSER"/.ssh
    chmod 700 /mnt/home/"$NEWUSER"/.ssh
    chmod 600 /mnt/home/"$NEWUSER"/.ssh/authorized_keys
fi

# Final cleanup
umount /mnt
echo "Installation complete! You can now reboot into SoltrOS."

