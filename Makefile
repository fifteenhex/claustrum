# =============================================================================
# Claustrum -- an immutable Debian VM that safely encloses Claude Code
#   (Latin claustrum, "an enclosed place", from claudere, "to shut in")
#   https://code.claude.com
#   - Immutable erofs root filesystem
#   - Persistent writable ext4 workspace disk mounted at /workspace
#
# Targets (make help for a cheat sheet):
#   make check-deps  - verify required host tools are installed
#   make base        - debootstrap Debian once, cache it as $(BASE_IMG)
#   make provision   - overlay on the base: kernel, dev tools, Claude Code
#   make reprovision - wipe ONLY the provision layer and redo it (base is
#                      cached; no new debootstrap, no Debian re-download)
#   make install PKGS="a b" - apt-install packages into the system image
#                      (writes into the provision layer, repacks the image)
#   make image       - pack the rootfs into a read-only erofs image
#   make workspace   - create the writable workspace disk (only if missing)
#   make qemu        - boot in QEMU (serial console, user networking)
#   make serial-attach SERIAL_DEV=/dev/ttyUSB0 - hot-plug a serial device
#                      into the running guest's /dev/ttyS1 (Ctrl-C unplugs)
#   make serial-log  - follow the serial traffic log
#   make ssh         - ssh into the running VM (port $(SSH_PORT))
#   make import REPO=<url> [NAME=<n>] - mirror a repo into the guest git
#                      server and create a working clone for Claude Code
#   make repos       - list repositories hosted in the guest
#   make clone NAME=<n> [DEST=<dir>]  - clone a guest repo onto the host
#   make convert-workspace - migrate an old raw workspace.img to qcow2
#   make put SRC=<p> [DEST=<p>] - copy host files/dirs into the guest
#   make get SRC=<p> [DEST=<p>] - copy guest files/dirs back to the host
#   make pull FILE=<p> [DEST=<p>] - like get, but relative to /workspace
#   make clean       - remove the rootfs image and extracted kernel
#   make clean-workspace - remove the workspace disk (DELETES YOUR DATA)
#   make distclean   - additionally remove the overlay layers and cached base
#
# Staging (erofs + overlayfs):
#   Stage 1's output is itself an erofs image, $(BASE_IMG): the pristine
#   debootstrap result, made once and cached. Stage 2 loop-mounts it
#   read-only and stacks a writable overlayfs upper layer on top; all
#   provisioning writes land in $(UPPER), never touching the base. The
#   final $(IMG) is packed from the merged view. Redoing provisioning is
#   therefore just discarding the upper layer (make reprovision) -- the
#   same immutable-lower/writable-upper split the final VM uses, applied
#   to the build itself.
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
#   - Git server: bare repos live in /workspace/git, working clones in
#     /workspace/src. From the host:
#       git clone ssh://$(DEVUSER)@localhost:$(SSH_PORT)/workspace/git/<name>.git
#     If $(HOST_PUBKEY) exists it is baked into the image at `make image`
#     time so host git/ssh access works without password prompts.
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
BASE_IMG   ?= $(CURDIR)/base-$(SUITE).erofs
LAYERS     ?= $(CURDIR)/layers
LOWER      := $(LAYERS)/lower
UPPER      := $(LAYERS)/upper
OVLWORK    := $(LAYERS)/work
MERGED     := $(LAYERS)/merged
IMG        ?= $(CURDIR)/claustrum.erofs
EROFS_OPTS ?= -zlz4hc
WS_IMG     ?= $(CURDIR)/workspace.qcow2
WS_SIZE    ?= 64G
# previous raw-format workspace, for `make convert-workspace`
WS_OLD_RAW ?= $(CURDIR)/workspace.img
VMNAME     ?= claustrum
DEVUSER    ?= dev
DEVPASS    ?= dev
ROOTPASS   ?= root
MEM        ?= 16G
# Default to half the host's CPUs (minimum 1); override with make CPUS=n
CPUS       ?= $(shell n=$$(nproc 2>/dev/null || echo 2); n=$$((n / 2)); [ $$n -ge 1 ] && echo $$n || echo 1)
SSH_PORT   ?= 2222
SUDO       ?= sudo

# First existing host SSH public key; baked into the image (if present) so
# ssh/git from the host needs no password. Override: make HOST_PUBKEY=path
HOST_PUBKEY ?= $(firstword $(wildcard $(HOME)/.ssh/id_ed25519.pub $(HOME)/.ssh/id_ecdsa.pub $(HOME)/.ssh/id_rsa.pub))

# On-demand serial sharing: qemu always exposes the guest's second serial
# port (/dev/ttyS1) as a listening TCP socket on localhost:$(SERIAL_PORT).
# Nothing is required at boot -- attach a physical adapter at any time with
# `make serial-attach SERIAL_DEV=/dev/ttyUSB0` (Ctrl-C detaches). The
# relay hex/text-dumps both directions to your terminal and $(SERIAL_LOG).
# NOTE: guest baud/termios on ttyS1 do not reach the physical adapter; set
# SERIAL_BAUD to match the hardware.
SERIAL_PORT ?= 7777
SERIAL_BAUD ?= 115200
SERIAL_LOG  ?= $(CURDIR)/serial-tap.log

# Guest-side git layout and host-side ssh plumbing
GUEST_GIT  := /workspace/git
GUEST_SRC  := /workspace/src
SSH_OPTS   := -p $(SSH_PORT) -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
GUEST_SSH  := ssh $(SSH_OPTS) $(DEVUSER)@localhost
GUEST_SCP  := scp -r -P $(SSH_PORT) -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null

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

 Git server:
   * bare repos      : /workspace/git   (host: make import REPO=<url>)
   * working clones  : /workspace/src   <- work in these
   * from the host   :
       git clone ssh://$(DEVUSER)@localhost:$(SSH_PORT)/workspace/git/<name>.git
   * Claude Code already knows this layout (claustrum-repos skill):
       just ask it to "work on <name>" and it takes it from there

 Good to know:
   * For interactive claude sessions, ssh in from the host (make ssh):
     a real terminal beats this serial console
   * Credentials persist in ~/.claude (lives on the workspace disk)
   * /           read-only erofs -- rebuild the image to change the OS
   * /workspace  writable, survives reboots and image rebuilds
   * apt install and self-update do not work here, by design
=======================================================================
endef
export MOTD

# A Claude Code "skill" baked into /etc/skel/.claude/skills, so it lands in
# the dev user's ~/.claude/skills when the home is created on first boot.
# Claude Code reads the description to decide when to load the skill.
define CLAUDE_SKILL
---
name: claustrum-repos
description: Working with git repositories inside this Claustrum sandbox VM. Use when asked to work on, clone, list, or set up a repository, or when starting any coding task that needs a repo.
---

# Repositories in Claustrum

This machine is an immutable sandbox VM with a local git server. All
repositories live on the writable workspace disk.

## Layout

- `/workspace/git/<name>.git` -- bare repositories: the local "server" and
  the `origin` of every working clone. The user on the host pushes to and
  fetches from these over SSH.
- `/workspace/src/<name>` -- working clones. Do all work here.

## Starting work on a repo

1. Look in `/workspace/src`. If a working clone exists, `cd` into it and work.
2. Otherwise look in `/workspace/git`. If `<name>.git` exists, clone it first:
   `git clone /workspace/git/<name>.git /workspace/src/<name>`
3. If the repo exists in neither place, it has not been imported yet. Ask
   the user to run this on the HOST (not in this VM):
   `make import REPO=<url>`

## Committing and sharing work

- Commit as usual and push to `origin` (the local bare repo). Push early and
  often: the user reviews your commits from the host via the same bare repo,
  and may push fixups you should `git pull`.
- Never push to external remotes (GitHub, GitLab, ...). This sandbox has no
  upstream credentials by design; publishing is the user's job on the host.

## Files from the user

The host can drop files into `/workspace/files` (via `make put` on the
host). When the user says they have shared or uploaded a file, look there.
To hand a file back, place it somewhere under `/workspace` and tell the
user its path; they retrieve it with `make get` on the host.

## Environment constraints

- The root filesystem is read-only: `apt install`, editing files outside
  `/workspace` or `$$HOME`, and self-updates all fail. This is intentional.
  Use project-level tooling instead (python venv, npm install in the repo).
- `/workspace` and `$$HOME` persist across reboots; `/tmp` and `/var/log` do not.
endef
export CLAUDE_SKILL

# Shell helpers to mount/unmount the erofs-lower + overlay-upper build stack.
# Expanded inside .ONESHELL recipes; the content survives verbatim because
# variable expansion happens after make's recipe-line processing.
define OVERLAY_SH
mount_stack() {
	$(SUDO) mkdir -p $(LOWER) $(UPPER) $(OVLWORK) $(MERGED)
	$(SUDO) mount -t erofs -o loop,ro $(BASE_IMG) $(LOWER)
	$(SUDO) mount -t overlay overlay \
		-o lowerdir=$(LOWER),upperdir=$(UPPER),workdir=$(OVLWORK) $(MERGED)
}
umount_stack() {
	$(SUDO) umount -l $(MERGED)/dev/pts $(MERGED)/dev $(MERGED)/sys $(MERGED)/proc 2>/dev/null || true
	$(SUDO) umount -l $(MERGED) 2>/dev/null || true
	$(SUDO) umount -l $(LOWER)  2>/dev/null || true
}
endef

# Login-shell fixup for serial consoles: the kernel reports a 0x0 window
# size on ttyS* and getty defaults TERM=vt220, which can send full-screen
# TUI apps (like Claude Code) into a 100%-CPU render spin. qemu -nographic
# forwards the host terminal, so xterm-256color is the accurate TERM.
define SERIAL_PROFILE
case "$$(tty 2>/dev/null)" in /dev/ttyS*)
case "$$TERM" in vt220|vt102|linux|"") export TERM=xterm-256color ;; esac
if [ "$$(stty size 2>/dev/null)" = "0 0" ]; then
stty rows 40 columns 140
fi
;;
esac
endef
export SERIAL_PROFILE

# ---- stamps -----------------------------------------------------------------
PROVISION_STAMP := $(LAYERS)/.provision-done

.PHONY: help all check-deps base rootfs provision clean-provision reprovision install install-pkgs put get pull convert-workspace serial-attach serial-log image workspace qemu ssh import repos clone clean clean-workspace distclean

# muscle-memory alias for the renamed stage
rootfs: base

define HELP
Claustrum -- immutable Debian VM for Claude Code

  make                  build everything (root image + workspace disk)
  make qemu             boot the VM        make ssh   shell into it
  make import REPO=url  put a repo in the guest git server
  make repos            list guest repos   make clone NAME=n  clone to host
  make put SRC=file     copy into guest    make pull FILE=path  copy back
                                           (FILE is relative to /workspace)
  make reprovision      redo provisioning on the cached Debian base
  make install PKGS="a b"  add packages to the system image
  make check-deps       verify host tools
  make serial-attach SERIAL_DEV=/dev/ttyUSB0   hot-plug a serial device
                        into guest ttyS1 (Ctrl-C unplugs; traffic shown live)

  Rebuild cost:  edit provisioning -> reprovision (minutes)
                 new Debian base   -> distclean, then make (slow)
  Safe to delete:  claustrum.erofs, layers/, vmlinuz, initrd.img
  Never auto-deleted:  workspace.qcow2 (your repos + claude login)

  Details, variables, troubleshooting: see README.md
endef
export HELP

help:
	@printf '%s\n' "$$HELP"

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
	check qemu-img         qemu-utils
	check ssh              openssh-client
	check git              git
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
	if ! grep -qw erofs /proc/filesystems && ! modinfo erofs >/dev/null 2>&1; then
		echo "warning: host kernel appears to lack erofs support; the build"
		echo "         loop-mounts the cached base image and will fail without it"
	fi
	echo "All host dependencies present."

# ---- 1. debootstrap once, cache the result as an erofs image ----------------
base: $(BASE_IMG)

$(BASE_IMG): | check-deps
	set -euo pipefail
	scratch=$(LAYERS)/base-root
	$(SUDO) rm -rf "$$scratch"
	mkdir -p $(LAYERS)
	$(SUDO) debootstrap \
		--arch=$(ARCH) \
		--include=$(BASE_PKGS) \
		$(SUITE) "$$scratch" $(MIRROR)
	$(SUDO) mkfs.erofs $(EROFS_OPTS) $@ "$$scratch"
	$(SUDO) chown $$(id -u):$$(id -g) $@
	$(SUDO) rm -rf "$$scratch"


# ---- 2. provision: kernel, tools, user, networking, claude ------------------
provision: $(PROVISION_STAMP)

$(PROVISION_STAMP): $(BASE_IMG) | check-deps
	set -euo pipefail
	$(OVERLAY_SH)
	trap umount_stack EXIT

	# Stack a writable overlay on the read-only cached base: everything
	# below writes into $(UPPER); $(BASE_IMG) is never modified
	mount_stack

	# DNS inside the chroot (rm first: resolv.conf may be a dangling symlink
	# left by systemd-resolved from a previous partial provisioning run)
	$(SUDO) rm -f $(MERGED)/etc/resolv.conf.chroot $(MERGED)/etc/resolv.conf
	$(SUDO) cp /etc/resolv.conf $(MERGED)/etc/resolv.conf.chroot
	$(SUDO) cp /etc/resolv.conf $(MERGED)/etc/resolv.conf

	# Bind mounts needed by apt/npm inside the chroot
	$(SUDO) mount -t proc  proc  $(MERGED)/proc
	$(SUDO) mount -t sysfs sysfs $(MERGED)/sys
	$(SUDO) mount --bind /dev     $(MERGED)/dev
	$(SUDO) mount --bind /dev/pts $(MERGED)/dev/pts

	$(SUDO) chroot $(MERGED) /bin/bash -eux <<-'EOF'
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
			useradd -M -d /workspace/home/$(DEVUSER) -s /bin/bash -G sudo,dialout $(DEVUSER)
		echo "$(DEVUSER):$(DEVPASS)" | chpasswd

		# create dev's home (with skeleton) on the workspace disk at boot,
		# after local-fs.target has mounted /dev/vdb
		cat > /etc/tmpfiles.d/workspace-home.conf <<TMPF
		d /workspace/home 0755 root root -
		C /workspace/home/$(DEVUSER) 0700 $(DEVUSER) $(DEVUSER) - /etc/skel
		Z /workspace/home/$(DEVUSER) 0700 $(DEVUSER) $(DEVUSER) -
		d /workspace/git 0755 $(DEVUSER) $(DEVUSER) -
		d /workspace/src 0755 $(DEVUSER) $(DEVUSER) -
		d /workspace/files 0755 $(DEVUSER) $(DEVUSER) -
		TMPF

		# ssh: also accept keys from the immutable /etc so the host's public
		# key can be baked into the image (dev's home doesn't exist yet)
		mkdir -p /etc/ssh/authorized_keys
		printf 'AuthorizedKeysFile /etc/ssh/authorized_keys/%%u .ssh/authorized_keys\n' \
			> /etc/ssh/sshd_config.d/10-claustrum.conf

		# networking: DHCP on any ethernet interface via systemd-networkd
		cat > /etc/systemd/network/20-wired.network <<NET
		[Match]
		Name=eth* en*

		[Network]
		DHCP=yes
		NET
		systemctl enable systemd-networkd systemd-resolved ssh

		# grow the workspace filesystem to fill its disk on every boot
		# (no-op when already full-size). Makes 'qemu-img resize' + reboot
		# the complete story for enlarging the workspace.
		cat > /etc/systemd/system/workspace-grow.service <<UNIT
		[Unit]
		Description=Grow /workspace filesystem to fill its disk
		After=workspace.mount
		Requires=workspace.mount
		[Service]
		Type=oneshot
		ExecStart=/usr/sbin/resize2fs /dev/vdb
		[Install]
		WantedBy=multi-user.target
		UNIT
		systemctl enable workspace-grow.service

		# mounts: immutable erofs root, writable workspace, tmpfs for scratch
		mkdir -p /workspace
		cat > /etc/fstab <<FSTAB
		/dev/vda /          erofs ro                  0 0
		/dev/vdb /workspace ext4  defaults,nofail     0 2
		tmpfs    /tmp       tmpfs defaults,mode=1777  0 0
		tmpfs    /var/tmp   tmpfs defaults,mode=1777  0 0
		tmpfs    /var/log   tmpfs defaults            0 0
		FSTAB

		# Claude Code -- baked into the immutable image, installed from
		# Anthropic's signed apt repository. This deliberately avoids the npm
		# route: npm v12 (July 2026) blocks install scripts by default and the
		# package needs its postinstall to link the native binary into place;
		# apt has no such moving parts and verifies package signatures itself.
		install -d -m 0755 /etc/apt/keyrings
		curl -fsSL https://downloads.claude.ai/keys/claude-code.asc \
			-o /etc/apt/keyrings/claude-code.asc
		# verify the published release-key fingerprint before trusting it
		gpg --show-keys --with-colons /etc/apt/keyrings/claude-code.asc \
			| grep -q '31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE'
		echo "deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main" \
			> /etc/apt/sources.list.d/claude-code.list
		apt-get update
		apt-get install -y claude-code
		apt-get clean
		claude --version

		# the immutable root can't self-update, so silence the auto-updater
		echo 'DISABLE_AUTOUPDATER=1' >> /etc/environment
		# also skip telemetry/update-check/error-report traffic: upstream
		# reports tie renderer CPU spins to failing telemetry exports, and a
		# sandbox shouldn't phone home anyway
		echo 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1' >> /etc/environment


		# system-wide git defaults (dev's home doesn't exist yet)
		git config --system init.defaultBranch main

		# last step: point resolv.conf at systemd-resolved for runtime
		# (dangling in the chroot, valid once the VM boots)
		rm -f /etc/resolv.conf
		ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
	EOF

	# message of the day: launch instructions on every login
	printf '%s\n' "$$MOTD" | $(SUDO) tee $(MERGED)/etc/motd >/dev/null

	# serial-console terminal fixup (see SERIAL_PROFILE comment above)
	printf '%s\n' "$$SERIAL_PROFILE" | \
		$(SUDO) tee $(MERGED)/etc/profile.d/serial-console.sh >/dev/null

	# Claude Code skill: teach the agent this VM's repo workflow. Lands in
	# ~/.claude/skills via /etc/skel when the home is created on first boot.
	$(SUDO) install -d $(MERGED)/etc/skel/.claude/skills/claustrum-repos
	printf '%s\n' "$$CLAUDE_SKILL" | \
		$(SUDO) tee $(MERGED)/etc/skel/.claude/skills/claustrum-repos/SKILL.md >/dev/null

	# restore the chroot-only resolv.conf hack (symlink was set inside)
	$(SUDO) rm -f $(MERGED)/etc/resolv.conf.chroot
	touch $@

# ---- 3. pack rootfs into a read-only erofs image, extract kernel/initrd -----
image: $(IMG)

$(IMG): $(PROVISION_STAMP) | check-deps
	set -euo pipefail
	$(OVERLAY_SH)
	trap umount_stack EXIT
	mount_stack
	# Copy kernel + initrd out of the merged view for qemu direct boot
	$(SUDO) sh -c 'cp $(MERGED)/boot/vmlinuz-*  $(KERNEL) && cp $(MERGED)/boot/initrd.img-* $(INITRD)'
	$(SUDO) chown $$(id -u):$$(id -g) $(KERNEL) $(INITRD)
	# Bake the host's ssh public key (if any) for passwordless git access;
	# done here (not in provisioning) so a key swap is just `make clean image`
	if [ -n "$(HOST_PUBKEY)" ]; then
		$(SUDO) install -m 644 -o root -g root $(HOST_PUBKEY) \
			$(MERGED)/etc/ssh/authorized_keys/$(DEVUSER)
	fi
	# Pack the merged (cached base + provision layer) view into the image
	rm -f $(IMG)
	$(SUDO) mkfs.erofs $(EROFS_OPTS) $(IMG) $(MERGED)
	$(SUDO) chown $$(id -u):$$(id -g) $(IMG)

# ---- 4. writable workspace disk (persistent; never rebuilt if present) ------
workspace: $(WS_IMG)

$(WS_IMG): | check-deps
	set -euo pipefail
	# mkfs can't write into qcow2 directly: format a sparse raw temp file,
	# then convert -- the resulting qcow2 only stores allocated clusters
	tmp=$(WS_IMG).raw.tmp
	rm -f "$$tmp"
	truncate -s $(WS_SIZE) "$$tmp"
	mkfs.ext4 -q -F -L workspace "$$tmp"
	qemu-img convert -f raw -O qcow2 "$$tmp" $(WS_IMG)
	rm -f "$$tmp"

# ---- 5. boot it --------------------------------------------------------------
qemu: $(IMG) $(WS_IMG) | check-deps
	qemu-system-x86_64 \
		-machine q35,accel=kvm:tcg -cpu max \
		-m $(MEM) -smp $(CPUS) \
		-kernel $(KERNEL) \
		-initrd $(INITRD) \
		-append "root=/dev/vda ro rootfstype=erofs console=ttyS0 net.ifnames=0 quiet" \
		-drive file=$(IMG),format=raw,if=virtio,read-only=on \
		-drive file=$(WS_IMG),format=qcow2,if=virtio \
		-netdev user,id=net0,hostfwd=tcp::$(SSH_PORT)-:22 \
		-device virtio-net-pci,netdev=net0 \
		-chardev socket,id=extser,host=127.0.0.1,port=$(SERIAL_PORT),server=on,wait=off \
		-serial mon:stdio -serial chardev:extser \
		-nographic

ssh:
	$(GUEST_SSH)

# ---- 6. git server -----------------------------------------------------------
# Mirror an upstream repo into the guest's git server and create a working
# clone for Claude Code. Requires the VM to be running (make qemu).
#   make import REPO=https://github.com/user/project.git [NAME=project]
import: | check-deps
	set -euo pipefail
	if [ -z "$(REPO)" ]; then
		echo "usage: make import REPO=<git-url> [NAME=<repo-name>]"; exit 1
	fi
	name="$(NAME)"; [ -n "$$name" ] || name="$$(basename "$(REPO)" .git)"
	echo "Importing $(REPO) -> guest:$(GUEST_GIT)/$$name.git"
	# --progress forces git's transfer meter even though stderr is a pipe
	# (over ssh it isn't a tty, so git would otherwise stay silent)
	$(GUEST_SSH) "set -e; \
		git clone --bare --progress '$(REPO)' '$(GUEST_GIT)/$$name.git'; \
		git -C '$(GUEST_GIT)/$$name.git' config receive.denyDeletes false; \
		git clone --progress '$(GUEST_GIT)/$$name.git' '$(GUEST_SRC)/$$name'"
	echo ""
	echo "Imported. Inside the guest, Claude Code works in: $(GUEST_SRC)/$$name"
	echo "From the host:"
	echo "  git clone ssh://$(DEVUSER)@localhost:$(SSH_PORT)$(GUEST_GIT)/$$name.git"

# List repositories hosted in the guest
repos: | check-deps
	$(GUEST_SSH) "ls -1 $(GUEST_GIT) 2>/dev/null | sed 's/\.git$$//'" || true

# Clone a guest repo onto the host: make clone NAME=project [DEST=dir]
clone: | check-deps
	set -euo pipefail
	if [ -z "$(NAME)" ]; then
		echo "usage: make clone NAME=<repo-name> [DEST=<dir>]"; exit 1
	fi
	GIT_SSH_COMMAND="ssh $(SSH_OPTS)" git clone \
		ssh://$(DEVUSER)@localhost:$(SSH_PORT)$(GUEST_GIT)/$(NAME).git $(DEST)

# Throw away ONLY the overlay provision layer; the cached base is untouched
clean-provision:
	set -euo pipefail
	$(OVERLAY_SH)
	umount_stack
	$(SUDO) rm -rf $(UPPER) $(OVLWORK) $(MERGED) $(LOWER)
	rm -f $(PROVISION_STAMP) $(IMG)

# Copy files or directories from the host into the guest (VM must be
# running). Default destination is the /workspace/files drop directory.
#   make put SRC=./data.csv            -> guest:/workspace/files/data.csv
#   make put SRC=./corpus DEST=/workspace/src/proj/corpus
put: | check-deps
	set -euo pipefail
	if [ -z "$(SRC)" ]; then
		echo 'usage: make put SRC=<host-path> [DEST=<guest-path>]'; exit 1
	fi
	dest="$(DEST)"; [ -n "$$dest" ] || dest=/workspace/files/
	# ensure the destination directory exists in the guest: a trailing slash
	# means dest IS the directory, otherwise its parent is
	case "$$dest" in
		*/) destdir="$$dest" ;;
		*)  destdir="$$(dirname "$$dest")" ;;
	esac
	$(GUEST_SSH) "mkdir -p '$$destdir'"
	$(GUEST_SCP) $(SRC) $(DEVUSER)@localhost:"$$dest"
	echo "-> guest:$$dest"

# Copy files or directories from the guest back to the host.
#   make get SRC=/workspace/files/report.pdf [DEST=.]
get: | check-deps
	set -euo pipefail
	if [ -z "$(SRC)" ]; then
		echo 'usage: make get SRC=<guest-path> [DEST=<host-path>]'; exit 1
	fi
	dest="$(DEST)"; [ -n "$$dest" ] || dest=.
	$(GUEST_SCP) $(DEVUSER)@localhost:"$(SRC)" "$$dest"

# Pull a file or directory from the guest workspace, by workspace-relative
# path (sugar over `make get`).
#   make pull FILE=files/report.pdf [DEST=.]
pull: | check-deps
	set -euo pipefail
	if [ -z "$(FILE)" ]; then
		echo 'usage: make pull FILE=<path-under-/workspace> [DEST=<host-path>]'; exit 1
	fi
	$(MAKE) get SRC="/workspace/$(FILE)" DEST="$(DEST)"

# One-time migration of a pre-existing raw workspace.img to qcow2 (and up
# to $(WS_SIZE)). Data is preserved; the old raw file is kept until you
# delete it yourself. The VM must be shut down first.
convert-workspace: | check-deps
	set -euo pipefail
	if [ ! -f $(WS_OLD_RAW) ]; then
		echo "no $(WS_OLD_RAW) to convert"; exit 1
	fi
	if [ -f $(WS_IMG) ]; then
		echo "$(WS_IMG) already exists; refusing to overwrite"; exit 1
	fi
	qemu-img convert -p -f raw -O qcow2 $(WS_OLD_RAW) $(WS_IMG)
	qemu-img resize $(WS_IMG) $(WS_SIZE)
	echo ""
	echo "Converted. The filesystem inside grows to $(WS_SIZE) automatically"
	echo "on the next boot (workspace-grow service). Old raw image kept at"
	echo "$(WS_OLD_RAW); delete it once you've verified the new one."

# Attach a local serial device to the running VM's ttyS1, on demand.
# Runs in the foreground showing traffic (and appending to $(SERIAL_LOG));
# Ctrl-C detaches. Re-run any time to re-attach.
#   make serial-attach SERIAL_DEV=/dev/ttyUSB0 [SERIAL_BAUD=115200]
serial-attach:
	set -euo pipefail
	if [ -z "$(SERIAL_DEV)" ]; then
		echo 'usage: make serial-attach SERIAL_DEV=/dev/ttyUSB0 [SERIAL_BAUD=...]'; exit 1
	fi
	command -v socat >/dev/null 2>&1 || {
		echo "needs socat on the host: sudo apt install socat"; exit 1; }
	[ -r "$(SERIAL_DEV)" ] && [ -w "$(SERIAL_DEV)" ] || {
		echo "cannot open $(SERIAL_DEV) -- add yourself to the host dialout group?"; exit 1; }
	echo "attaching $(SERIAL_DEV) @$(SERIAL_BAUD) -> guest /dev/ttyS1 (Ctrl-C detaches)"
	socat -x -v \
		$(SERIAL_DEV),raw,echo=0,b$(SERIAL_BAUD) \
		TCP:127.0.0.1:$(SERIAL_PORT) \
		2>&1 | tee -a $(SERIAL_LOG)

# Follow the serial traffic log without being the attach terminal
serial-log:
	tail -f $(SERIAL_LOG)

# Redo provisioning from the pristine cached base: no debootstrap,
# no Debian re-download -- typically the apt mirror fetch is all that's left
reprovision: clean-provision
	$(MAKE) image

# Install extra packages into the system image without a full reprovision:
# chroot into the overlay, apt-get install, repack. The packages land in the
# provision layer, so they persist across image rebuilds -- but NOT across
# `make reprovision`; add them to DEV_PKGS for that.
#   make install PKGS="htop strace"
install-pkgs:
	set -euo pipefail
	if [ -z "$(PKGS)" ]; then
		echo 'usage: make install PKGS="pkg1 pkg2 ..."'; exit 1
	fi
	if [ ! -f $(PROVISION_STAMP) ]; then
		echo "no provision layer yet -- run 'make image' first"; exit 1
	fi
	$(OVERLAY_SH)
	trap umount_stack EXIT
	mount_stack
	# temporary working DNS in the chroot (the baked resolv.conf points into
	# /run, which dangles here); the guest-runtime symlink is restored below
	$(SUDO) rm -f $(MERGED)/etc/resolv.conf
	$(SUDO) cp /etc/resolv.conf $(MERGED)/etc/resolv.conf
	$(SUDO) mount -t proc  proc  $(MERGED)/proc
	$(SUDO) mount -t sysfs sysfs $(MERGED)/sys
	$(SUDO) mount --bind /dev     $(MERGED)/dev
	$(SUDO) mount --bind /dev/pts $(MERGED)/dev/pts
	$(SUDO) chroot $(MERGED) /bin/bash -euxc '\
		export DEBIAN_FRONTEND=noninteractive; \
		apt-get update; \
		apt-get install -y $(PKGS); \
		apt-get clean; \
		rm -f /etc/resolv.conf; \
		ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf'
	touch $(PROVISION_STAMP)
	echo ""
	echo "Installed into the provision layer: $(PKGS)"
	echo "Note: add them to DEV_PKGS to survive a future 'make reprovision'."

install: install-pkgs
	$(MAKE) image

# ---- housekeeping ------------------------------------------------------------
clean:
	rm -f $(IMG) $(KERNEL) $(INITRD)

clean-workspace:
	@echo "This deletes all data in $(WS_IMG). Ctrl-C to abort."; sleep 3
	rm -f $(WS_IMG)

distclean: clean
	set -euo pipefail
	$(OVERLAY_SH)
	umount_stack
	$(SUDO) rm -rf $(LAYERS)
	rm -f $(BASE_IMG)
