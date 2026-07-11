# =============================================================================
# Claustrum -- an immutable Debian VM that safely encloses Claude Code
#   (Latin claustrum, "an enclosed place", from claudere, "to shut in")
#   https://code.claude.com
#   - Immutable erofs root filesystem
#   - Persistent writable ext4 workspace disk mounted at /workspace
#
# Targets:
#   make check-deps  - verify required host tools are installed
#   make rootfs      - debootstrap a base Debian system into $(ROOTFS)
#   make provision   - install kernel, dev tools, git, node, and Claude Code
#   make image       - pack the rootfs into a read-only erofs image
#   make workspace   - create the writable workspace disk (only if missing)
#   make qemu        - boot in QEMU (serial console, user networking)
#   make ssh         - ssh into the running VM (port $(SSH_PORT))
#   make clean       - remove the rootfs image and extracted kernel
#   make clean-workspace - remove the workspace disk (DELETES YOUR DATA)
#   make distclean   - additionally remove the rootfs tree (needs sudo)
#
# Host requirements (Debian/Ubuntu):
#   sudo apt install debootstrap qemu-system-x86 e2fsprogs erofs-utils
#
# Notes:
#   - The root disk (/dev/vda) is erofs: read-only by construction. To change
#     the system, edit provisioning, then `make clean image` to rebuild.
#   - /dev/vdb is a normal ext4 disk mounted at /workspace. It survives
#     rebuilds of the root image; `make clean` never touches it.
#   - The dev user's home lives on the workspace disk, so Claude Code's
#     config and auth (~/.claude) persist across boots and image rebuilds.
#   - Ephemeral state (/tmp, /var/tmp, /var/log) is tmpfs.
#   - Boots via qemu direct kernel boot (-kernel), so no bootloader needed.
#   - Log in as $(DEVUSER) / $(DEVPASS) (or root / $(ROOTPASS)).
# =============================================================================

SHELL := /bin/bash
.ONESHELL:

# Debian installs admin tools (debootstrap, mkfs.erofs, mkfs.ext4, ...) into
# /usr/sbin, which is NOT on a regular user's PATH by default -- so both the
# dependency check and unprivileged mkfs calls would fail even with the
# packages installed. Extend PATH for every recipe in this Makefile.
export PATH := $(PATH):/usr/local/sbin:/usr/sbin:/sbin

# ---- configuration ----------------------------------------------------------
ARCH       ?= amd64
# Debian suite: "testing" for up-to-date tooling; set SUITE=trixie (or the
# current stable codename) if you prefer a stable base.
SUITE      ?= testing
MIRROR     ?= http://deb.debian.org/debian
ROOTFS     ?= $(CURDIR)/rootfs
IMG        ?= $(CURDIR)/claustrum.erofs
EROFS_OPTS ?= -zlz4hc
WS_IMG     ?= $(CURDIR)/workspace.img
WS_SIZE    ?= 20G
VMNAME     ?= claustrum
DEVUSER    ?= dev
DEVPASS    ?= dev
ROOTPASS   ?= root
MEM        ?= 4G
CPUS       ?= 2
SSH_PORT   ?= 2222
SUDO       ?= sudo

KERNEL     := $(CURDIR)/vmlinuz
INITRD     := $(CURDIR)/initrd.img

# Base packages pulled in by debootstrap itself
BASE_PKGS := systemd-sysv,dbus,locales,ca-certificates,curl,wget,gnupg,sudo,openssh-server

# Everything a coding agent needs to be useful, installed during provisioning
DEV_PKGS := \
	linux-image-$(ARCH) \
	initramfs-tools \
	systemd-resolved \
	build-essential pkg-config \
	git git-lfs \
	python3 python3-pip python3-venv \
	nodejs npm \
	vim nano less man-db \
	ripgrep fd-find jq tree tmux \
	unzip zip file procps psmisc \
	openssh-client netcat-openbsd iproute2 iputils-ping

# Login banner, written to /etc/motd during provisioning. Kept in a define
# (not in the recipe heredoc) because .ONESHELL strips leading whitespace and
# @/-/+ prefix characters from every recipe line, which destroys ASCII layout.
define MOTD
=======================================================================
 Claustrum -- an immutable enclosure for Claude Code
-----------------------------------------------------------------------
 Quick start:

     cd /workspace
     claude

 First run, pick a login method:
   * Subscription : run claude, open the printed URL in a browser
                    on your host machine, paste the code back here
   * API key      : export ANTHROPIC_API_KEY=sk-ant-...  then run claude

 Good to know:
   * Credentials persist in ~/.claude (lives on the workspace disk)
   * /           read-only erofs -- rebuild the image to change the OS
   * /workspace  writable, survives reboots and image rebuilds
   * apt install and self-update do not work here, by design
=======================================================================
endef
export MOTD

# ---- stamps -----------------------------------------------------------------
DEBOOTSTRAP_STAMP := $(ROOTFS)/.debootstrap-done
PROVISION_STAMP   := $(ROOTFS)/.provision-done

.PHONY: all check-deps rootfs provision image workspace qemu ssh clean clean-workspace distclean

all: image workspace

# ---- 0. host dependency check ------------------------------------------------
# Verifies every tool used by this Makefile exists on the host, and prints the
# exact apt command to fix whatever is missing. Runs as an order-only
# prerequisite (| check-deps) of the real targets, so it executes every time
# without dirtying their timestamps.
check-deps:
	@set -u
	missing=""
	check() {
		command -v "$$1" >/dev/null 2>&1 || {
			echo "missing: $$1 (host package: $$2)"
			case " $$missing " in *" $$2 "*) ;; *) missing="$$missing $$2" ;; esac
		}
	}
	check sudo             sudo
	check debootstrap      debootstrap
	check chroot           coreutils
	check truncate         coreutils
	check mkfs.erofs       erofs-utils
	check mkfs.ext4        e2fsprogs
	check qemu-system-x86_64 qemu-system-x86
	check ssh              openssh-client
	if [ -n "$$missing" ]; then
		echo ""
		echo "Missing host dependencies. Install them with:"
		echo "  sudo apt install$$missing"
		exit 1
	fi
	# non-fatal warnings
	if ! mkfs.erofs --help 2>&1 | grep -q 'lz4hc'; then
		echo "warning: mkfs.erofs lacks lz4hc support; build with EROFS_OPTS= or EROFS_OPTS=-zzstd"
	fi
	if [ ! -w /dev/kvm ]; then
		echo "warning: /dev/kvm not accessible; qemu will fall back to slow TCG emulation"
	fi
	echo "All host dependencies present."

# ---- 1. debootstrap the base system -----------------------------------------
rootfs: $(DEBOOTSTRAP_STAMP)

$(DEBOOTSTRAP_STAMP): | check-deps
	set -euo pipefail
	$(SUDO) debootstrap \
		--arch=$(ARCH) \
		--include=$(BASE_PKGS) \
		$(SUITE) $(ROOTFS) $(MIRROR)
	$(SUDO) touch $@

# ---- 2. provision: kernel, tools, user, networking, claude ------------------
provision: $(PROVISION_STAMP)

$(PROVISION_STAMP): $(DEBOOTSTRAP_STAMP) | check-deps
	set -euo pipefail

	# DNS inside the chroot (rm first: resolv.conf may be a dangling symlink
	# left by systemd-resolved from a previous partial provisioning run)
	$(SUDO) rm -f $(ROOTFS)/etc/resolv.conf.chroot $(ROOTFS)/etc/resolv.conf
	$(SUDO) cp /etc/resolv.conf $(ROOTFS)/etc/resolv.conf.chroot
	$(SUDO) cp /etc/resolv.conf $(ROOTFS)/etc/resolv.conf

	# Bind mounts needed by apt/npm inside the chroot
	$(SUDO) mount -t proc  proc  $(ROOTFS)/proc
	$(SUDO) mount -t sysfs sysfs $(ROOTFS)/sys
	$(SUDO) mount --bind /dev     $(ROOTFS)/dev
	$(SUDO) mount --bind /dev/pts $(ROOTFS)/dev/pts

	cleanup() {
		$(SUDO) umount -l $(ROOTFS)/dev/pts $(ROOTFS)/dev $(ROOTFS)/sys $(ROOTFS)/proc || true
	}
	trap cleanup EXIT

	$(SUDO) chroot $(ROOTFS) /bin/bash -eux <<-'EOF'
		export DEBIAN_FRONTEND=noninteractive

		# hostname / hosts
		echo "$(VMNAME)" > /etc/hostname
		printf '127.0.0.1\tlocalhost\n127.0.1.1\t$(VMNAME)\n' > /etc/hosts

		# locale
		sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
		locale-gen
		update-locale LANG=en_US.UTF-8

		# packages (kernel + dev tooling)
		apt-get update
		apt-get install -y $(DEV_PKGS)
		apt-get clean

		# installing systemd-resolved replaces /etc/resolv.conf with a symlink
		# into /run, which dangles inside the chroot -- restore working DNS
		# for the remaining steps (npm needs it); the symlink is re-created
		# at the end of this script
		rm -f /etc/resolv.conf
		cp /etc/resolv.conf.chroot /etc/resolv.conf

		# make sure the initramfs can mount an erofs root.
		# initramfs-tools is pinned in DEV_PKGS because Debian forky/testing
		# switched the kernel's default initramfs generator to dracut; if a
		# previous rootfs had dracut, apt swaps it out and the initrd must be
		# regenerated from scratch (-c) since initramfs-tools tracks nothing yet
		echo erofs >> /etc/initramfs-tools/modules
		update-initramfs -u -k all || true
		update-initramfs -c -k all || true
		ls /boot/initrd.img-*   # assert an initrd actually exists (set -e)

		# bake in identity/state that a read-only root can't create at runtime
		[ -s /etc/machine-id ] || systemd-machine-id-setup
		ssh-keygen -A

		# users -- dev's home lives on the writable workspace disk (/dev/vdb),
		# so don't create it in the (soon to be immutable) rootfs
		echo "root:$(ROOTPASS)" | chpasswd
		id -u $(DEVUSER) >/dev/null 2>&1 || \
			useradd -M -d /workspace/home/$(DEVUSER) -s /bin/bash -G sudo $(DEVUSER)
		echo "$(DEVUSER):$(DEVPASS)" | chpasswd

		# create dev's home (with skeleton) on the workspace disk at boot,
		# after local-fs.target has mounted /dev/vdb
		cat > /etc/tmpfiles.d/workspace-home.conf <<TMPF
		d /workspace/home 0755 root root -
		C /workspace/home/$(DEVUSER) 0700 $(DEVUSER) $(DEVUSER) - /etc/skel
		Z /workspace/home/$(DEVUSER) 0700 $(DEVUSER) $(DEVUSER) -
		TMPF

		# networking: DHCP on any ethernet interface via systemd-networkd
		cat > /etc/systemd/network/20-wired.network <<NET
		[Match]
		Name=en*

		[Network]
		DHCP=yes
		NET
		systemctl enable systemd-networkd systemd-resolved ssh

		# mounts: immutable erofs root, writable workspace, tmpfs for scratch
		mkdir -p /workspace
		cat > /etc/fstab <<FSTAB
		/dev/vda /          erofs ro                  0 0
		/dev/vdb /workspace ext4  defaults,nofail     0 2
		tmpfs    /tmp       tmpfs defaults,mode=1777  0 0
		tmpfs    /var/tmp   tmpfs defaults,mode=1777  0 0
		tmpfs    /var/log   tmpfs defaults            0 0
		FSTAB

		# Claude Code -- baked into the immutable image.
		# NOTE: do NOT use --ignore-scripts here: the npm package ships a
		# native binary via per-platform optional dependencies and links it
		# into place in a postinstall step; skipping scripts breaks it.
		npm install -g @anthropic-ai/claude-code
		claude --version

		# the immutable root can't self-update, so silence the auto-updater
		echo 'DISABLE_AUTOUPDATER=1' >> /etc/environment


		# system-wide git defaults (dev's home doesn't exist yet)
		git config --system init.defaultBranch main

		# last step: point resolv.conf at systemd-resolved for runtime
		# (dangling in the chroot, valid once the VM boots)
		rm -f /etc/resolv.conf
		ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
	EOF

	# message of the day: launch instructions on every login
	printf '%s\n' "$$MOTD" | $(SUDO) tee $(ROOTFS)/etc/motd >/dev/null

	# restore the chroot-only resolv.conf hack (symlink was set inside)
	$(SUDO) rm -f $(ROOTFS)/etc/resolv.conf.chroot
	$(SUDO) touch $@

# ---- 3. pack rootfs into a read-only erofs image, extract kernel/initrd -----
image: $(IMG)

$(IMG): $(PROVISION_STAMP) | check-deps
	set -euo pipefail
	# Copy kernel + initrd out of the rootfs for qemu direct boot
	$(SUDO) sh -c 'cp $(ROOTFS)/boot/vmlinuz-*  $(KERNEL) && cp $(ROOTFS)/boot/initrd.img-* $(INITRD)'
	$(SUDO) chown $$(id -u):$$(id -g) $(KERNEL) $(INITRD)
	# Build the erofs image directly from the directory tree
	rm -f $(IMG)
	$(SUDO) mkfs.erofs $(EROFS_OPTS) \
		--exclude-regex '^\.(debootstrap|provision)-done$$' \
		$(IMG) $(ROOTFS)
	$(SUDO) chown $$(id -u):$$(id -g) $(IMG)

# ---- 4. writable workspace disk (persistent; never rebuilt if present) ------
workspace: $(WS_IMG)

$(WS_IMG): | check-deps
	set -euo pipefail
	truncate -s $(WS_SIZE) $(WS_IMG)
	mkfs.ext4 -q -F -L workspace $(WS_IMG)

# ---- 5. boot it --------------------------------------------------------------
qemu: $(IMG) $(WS_IMG) | check-deps
	qemu-system-x86_64 \
		-machine q35,accel=kvm:tcg \
		-m $(MEM) -smp $(CPUS) \
		-kernel $(KERNEL) \
		-initrd $(INITRD) \
		-append "root=/dev/vda ro rootfstype=erofs console=ttyS0 net.ifnames=0 quiet" \
		-drive file=$(IMG),format=raw,if=virtio,read-only=on \
		-drive file=$(WS_IMG),format=raw,if=virtio \
		-netdev user,id=net0,hostfwd=tcp::$(SSH_PORT)-:22 \
		-device virtio-net-pci,netdev=net0 \
		-nographic

ssh:
	ssh -p $(SSH_PORT) -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $(DEVUSER)@localhost

# ---- housekeeping ------------------------------------------------------------
clean:
	rm -f $(IMG) $(KERNEL) $(INITRD)

clean-workspace:
	@echo "This deletes all data in $(WS_IMG). Ctrl-C to abort."; sleep 3
	rm -f $(WS_IMG)

distclean: clean
	$(SUDO) rm -rf $(ROOTFS)
