# =============================================================================
# Claustrum -- an immutable Debian VM that safely encloses Claude Code
#   (Latin claustrum, "an enclosed place", from claudere, "to shut in")
#   https://code.claude.com
#   - Immutable erofs root filesystem
#   - Persistent writable ext4 workspace disk mounted at /workspace
#
# Targets:
#   make check-deps  - verify required host tools are installed
#   make base        - debootstrap Debian once, cache it as $(BASE_IMG)
#   make provision   - overlay on the base: kernel, dev tools, Claude Code
#   make reprovision - wipe ONLY the provision layer and redo it (base is
#                      cached; no new debootstrap, no Debian re-download)
#   make image       - pack the rootfs into a read-only erofs image
#   make workspace   - create the writable workspace disk (only if missing)
#   make qemu        - boot in QEMU (serial console, user networking)
#   make ssh         - ssh into the running VM (port $(SSH_PORT))
#   make import REPO=<url> [NAME=<n>] - mirror a repo into the guest git
#                      server and create a working clone for Claude Code
#   make repos       - list repositories hosted in the guest
#   make clone NAME=<n> [DEST=<dir>]  - clone a guest repo onto the host
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

# First existing host SSH public key; baked into the image (if present) so
# ssh/git from the host needs no password. Override: make HOST_PUBKEY=path
HOST_PUBKEY ?= $(firstword $(wildcard $(HOME)/.ssh/id_ed25519.pub $(HOME)/.ssh/id_ecdsa.pub $(HOME)/.ssh/id_rsa.pub))

# Guest-side git layout and host-side ssh plumbing
GUEST_GIT  := /workspace/git
GUEST_SRC  := /workspace/src
SSH_OPTS   := -p $(SSH_PORT) -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
GUEST_SSH  := ssh $(SSH_OPTS) $(DEVUSER)@localhost

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

# ---- stamps -----------------------------------------------------------------
PROVISION_STAMP := $(LAYERS)/.provision-done

.PHONY: all check-deps base rootfs provision clean-provision reprovision image workspace qemu ssh import repos clone clean clean-workspace distclean

# muscle-memory alias for the renamed stage
rootfs: base

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
			useradd -M -d /workspace/home/$(DEVUSER) -s /bin/bash -G sudo $(DEVUSER)
		echo "$(DEVUSER):$(DEVPASS)" | chpasswd

		# create dev's home (with skeleton) on the workspace disk at boot,
		# after local-fs.target has mounted /dev/vdb
		cat > /etc/tmpfiles.d/workspace-home.conf <<TMPF
		d /workspace/home 0755 root root -
		C /workspace/home/$(DEVUSER) 0700 $(DEVUSER) $(DEVUSER) - /etc/skel
		Z /workspace/home/$(DEVUSER) 0700 $(DEVUSER) $(DEVUSER) -
		d /workspace/git 0755 $(DEVUSER) $(DEVUSER) -
		d /workspace/src 0755 $(DEVUSER) $(DEVUSER) -
		TMPF

		# ssh: also accept keys from the immutable /etc so the host's public
		# key can be baked into the image (dev's home doesn't exist yet)
		mkdir -p /etc/ssh/authorized_keys
		printf 'AuthorizedKeysFile /etc/ssh/authorized_keys/%%u .ssh/authorized_keys\n' \
			> /etc/ssh/sshd_config.d/10-claustrum.conf

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


		# system-wide git defaults (dev's home doesn't exist yet)
		git config --system init.defaultBranch main

		# last step: point resolv.conf at systemd-resolved for runtime
		# (dangling in the chroot, valid once the VM boots)
		rm -f /etc/resolv.conf
		ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
	EOF

	# message of the day: launch instructions on every login
	printf '%s\n' "$$MOTD" | $(SUDO) tee $(MERGED)/etc/motd >/dev/null

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
	$(GUEST_SSH) "set -e; \
		git clone --bare '$(REPO)' '$(GUEST_GIT)/$$name.git'; \
		git -C '$(GUEST_GIT)/$$name.git' config receive.denyDeletes false; \
		git clone '$(GUEST_GIT)/$$name.git' '$(GUEST_SRC)/$$name'"
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

# Redo provisioning from the pristine cached base: no debootstrap,
# no Debian re-download -- typically the apt mirror fetch is all that's left
reprovision: clean-provision
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
