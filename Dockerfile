# Build image for OpenWrt (econet/en7528, Nokia G-2425G-A) firmware.
#
# The image only carries the *host* toolchain prerequisites. The upstream
# OpenWrt source is cloned at run time by build.sh, so nothing about OpenWrt
# itself is baked in here except the packages needed to compile it.
#
# Arch note: this builds natively on the host architecture. On Apple Silicon
# that means a native arm64 image (no QEMU) - the target is still mipsel, the
# host tools are just arm64. gcc-multilib is x86-only and is only installed on
# amd64 hosts.

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

# Core OpenWrt build dependencies (see openwrt.org buildsystem prerequisites)
# plus the extras this repo needs (ccache, pyelftools for dtc/ELF, subversion
# and friends for `feeds`).
RUN set -eux; \
	apt-get update; \
	EXTRA=""; \
	if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
		EXTRA="gcc-multilib g++-multilib"; \
	fi; \
	apt-get install -y --no-install-recommends \
		build-essential clang flex bison g++ gawk gettext \
		git libncurses-dev libssl-dev \
		python3 python3-dev python3-setuptools python3-yaml python3-pyelftools \
		rsync unzip zip zlib1g-dev file wget ca-certificates \
		ccache subversion swig time libelf-dev \
		bc cpio patch \
		autoconf automake libtool-bin pkg-config gperf \
		zstd xz-utils bzip2 gzip tar \
		less vim-tiny sudo \
		$EXTRA; \
	apt-get clean; \
	rm -rf /var/lib/apt/lists/*

# Keep the build deterministic regardless of the caller's locale.
ENV LC_ALL=C
ENV LANG=C

# The container builds as root. A few upstream host tools (GNU tar, and others)
# abort their `configure` step when euid is 0 unless this is set. It is contained
# here: the repo is mounted read-only and the build tree is a dedicated volume.
# Set in the image (not the entrypoint) so `docker compose run shell` gets it too.
ENV FORCE_UNSAFE_CONFIGURE=1

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# /build/work  : persistent, case-sensitive build tree (a named volume)
# /build/artifacts : produced firmware, bind-mounted out to the host
# /src         : the mounted repository (read-only)
WORKDIR /build

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
