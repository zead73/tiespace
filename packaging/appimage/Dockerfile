# Old-glibc build environment for a portable tiespace AppImage.
#
# AlmaLinux 9 -> glibc 2.34 + OpenSSL 3, so the resulting AppImage runs on every
# currently-supported mainstream distro (Ubuntu 22.04+, Debian 12, RHEL/Alma 9,
# Fedora, Arch, …). A binary built here demands only glibc <= 2.34 at runtime,
# and the bundled libraries carry the same low floor.
#
# For older targets (glibc 2.28: RHEL 8 / Ubuntu 20.04) switch the base to
# almalinux:8 — but note it ships OpenSSL 1.1.x, so you'd build OpenSSL 3 from
# source or accept the older library.
FROM almalinux:9

# Build deps. OpenSSL is dlopen'd at runtime, but we install openssl-libs so it's
# present to *bundle*; ncurses-devel provides the link-time libncursesw. (curl is
# already present as curl-minimal, which conflicts with the full curl package.)
RUN dnf -y install ncurses-devel openssl-libs gcc binutils make which findutils \
      tar gzip xz file \
    && dnf clean all

# FPC 3.2.2 from upstream — glibc-2.34 distro packages of FPC lag the version
# tiespace targets. `yes ''` accepts the installer's defaults (prefix /usr).
ARG FPC=3.2.2
RUN curl -fL -o /tmp/fpc.tar \
      "https://downloads.sourceforge.net/project/freepascal/Linux/${FPC}/fpc-${FPC}.x86_64-linux.tar" \
    && mkdir /tmp/fpc && tar -C /tmp/fpc --strip-components=1 -xf /tmp/fpc.tar \
    && ( cd /tmp/fpc && yes '' | ./install.sh ) \
    && rm -rf /tmp/fpc /tmp/fpc.tar \
    && fpc -iV

# appimagetool — the current build is a static ELF (bundles mksquashfs), so no
# FUSE is needed to *package* the AppImage.
RUN curl -fL -o /usr/local/bin/appimagetool \
      https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage \
    && chmod +x /usr/local/bin/appimagetool

# appimagetool is itself an AppImage; inside a container there's no FUSE, so tell
# it (and any AppImage) to self-extract and run instead of FUSE-mounting.
ENV APPIMAGE_EXTRACT_AND_RUN=1

WORKDIR /src
ENTRYPOINT ["packaging/appimage/build.sh"]
