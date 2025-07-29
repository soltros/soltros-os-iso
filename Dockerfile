# Set base image and tag
ARG BASE_IMAGE=quay.io/fedora/fedora-bootc
ARG TAG_VERSION=latest
FROM ${BASE_IMAGE}:${TAG_VERSION}

# Stage 1: context for scripts (not included in final image)
FROM ${BASE_IMAGE}:${TAG_VERSION} AS ctx
COPY build_files/ /ctx/
COPY soltros.pub /ctx/soltros.pub

# Change perms
RUN chmod +x \
    /ctx/build.sh \
    /ctx/signing.sh \
    /ctx/cleanup.sh \
    /ctx/desktop-packages.sh

# Stage 2: final image
FROM ${BASE_IMAGE}:${TAG_VERSION} AS soltros

LABEL org.opencontainers.image.title="SoltrOS Live ISO" \
    org.opencontainers.image.description="Server-ready RPM OSTree image with Docker CE support" \
    org.opencontainers.image.vendor="Derrik" \
    org.opencontainers.image.version="1"

# Copy system files
COPY system_files/usr /usr

# Create necessary directories for shell configurations
RUN mkdir -p /etc/profile.d /etc/fish/conf.d

RUN dnf5 install --setopt=install_weak_deps=False --nogpgcheck --skip-unavailable -y NetworkManager nmcli

# Get rid of Plymouth

RUN dnf5 remove plymouth* -y && \
    systemctl disable plymouth-start.service plymouth-read-write.service plymouth-quit.service plymouth-quit-wait.service plymouth-reboot.service plymouth-kexec.service plymouth-halt.service plymouth-poweroff.service 2>/dev/null || true && \
    rm -rf /usr/share/plymouth /usr/lib/plymouth /etc/plymouth && \
    rm -f /usr/lib/systemd/system/plymouth* /usr/lib/systemd/system/*/plymouth* && \
    rm -f /usr/bin/plymouth /usr/sbin/plymouthd && \
    sed -i 's/rhgb quiet//' /etc/default/grub 2>/dev/null || true && \
    sed -i 's/splash//' /etc/default/grub 2>/dev/null || true && \
    sed -i '/plymouth/d' /etc/dracut.conf.d/* 2>/dev/null || true && \
    echo 'omit_dracutmodules+=" plymouth "' > /etc/dracut.conf.d/99-disable-plymouth.conf && \
    grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true && \
    dracut -f 2>/dev/null || true && \
    dnf5 autoremove -y && \
    dnf5 clean all
    
# Mount and run build script from ctx stage
ARG BASE_IMAGE
RUN --mount=type=bind,from=ctx,source=/ctx,target=/ctx \
    --mount=type=tmpfs,dst=/tmp \
    BASE_IMAGE=$BASE_IMAGE bash /ctx/build.sh
