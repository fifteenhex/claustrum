# Claustrum

*Latin **claustrum**: "an enclosed place, a barrier" — from **claudere**,
"to shut in" — the root of* cloister. *The word for a safe enclosure
literally begins with Claude, and that is exactly what this is.*

Claustrum is a single Makefile that builds a small, immutable QEMU virtual
machine for running [Claude Code](https://code.claude.com) safely shut in:

- **Immutable root filesystem** — the OS lives on a read-only [erofs](https://docs.kernel.org/filesystems/erofs.html)
  image (`/dev/vda`). Nothing running inside the VM can modify the system, by
  construction: the filesystem is read-only and QEMU attaches the disk
  `read-only=on` as well.
- **Persistent workspace disk** — a plain ext4 image (`/dev/vdb`) mounted at
  `/workspace` in the guest. Your code, and the dev user's home directory
  (including Claude Code's `~/.claude` config and auth), live here and
  survive rebuilds of
  the root image.
- **Batteries included** — Debian *testing* with git, build-essential,
  Python 3 (pip/venv), Node.js, ripgrep, fd, jq, tmux, vim, an SSH server,
  and Claude Code itself (`@anthropic-ai/claude-code`) preinstalled.
- **No bootloader** — the VM boots via QEMU direct kernel boot (`-kernel`),
  so there is no grub or EFI partition to manage.

Running a coding agent inside a throwaway VM is a sensible default. Claude
Code has a permission system, but if you like running it with permission
prompts relaxed (e.g. `--dangerously-skip-permissions` for long unattended
sessions), a sandbox with an immutable OS and no access to your real home
directory is exactly the kind of container that makes that reasonable.

## Requirements

A Debian or Ubuntu host with:

```sh
sudo apt install debootstrap qemu-system-x86 e2fsprogs erofs-utils
```

`make check-deps` verifies all of this and prints the exact install command
for anything missing. It also warns (non-fatally) if `/dev/kvm` is not
accessible — the VM still boots, just slowly, under TCG emulation. To use
KVM, add yourself to the `kvm` group and log in again:

```sh
sudo usermod -aG kvm $USER
```

Building requires `sudo` (debootstrap and chroot need root).

## Quick start

```sh
make                # builds the root image and the workspace disk (~10 min)
make qemu           # boots the VM on the serial console
```

Log in as `dev` / `dev` (or `root` / `root`), then:

```sh
cd /workspace
claude              # follow the login flow, or export ANTHROPIC_API_KEY first
```

Claude Code requires a paid plan (Pro, Max, Team, Enterprise) or an
Anthropic Console account billed at API rates. On a headless VM the OAuth
flow gives you a URL to open in a browser on your host; alternatively set
`ANTHROPIC_API_KEY`. Credentials are stored in `~/.claude`, which lives on
the workspace disk — so you only need to authenticate once.

To quit QEMU on the serial console: `Ctrl-a x`. To SSH in from the host
instead (port 2222 is forwarded): `make ssh`.

## Targets

| Target                 | What it does                                                        |
| ---------------------- | ------------------------------------------------------------------- |
| `make check-deps`      | Verify required host tools; print `apt install` line for the rest   |
| `make rootfs`          | debootstrap a base Debian system into `./rootfs`                    |
| `make provision`       | chroot in; install kernel, dev tools, users, networking, and claude |
| `make image`           | Pack the rootfs into the read-only erofs image + extract kernel     |
| `make workspace`       | Create the writable workspace disk (only if it doesn't exist)       |
| `make qemu`            | Boot the VM (serial console, virtio disks/net, SSH on host :2222)   |
| `make ssh`             | SSH into the running VM as the dev user                             |
| `make import REPO=url` | Mirror a repo into the guest git server + create a working clone    |
| `make repos`           | List repositories hosted in the guest                               |
| `make clone NAME=n`    | Clone a guest repo onto the host over SSH                           |
| `make clean`           | Remove the root image, kernel, and initrd (workspace untouched)     |
| `make clean-workspace` | Delete the workspace disk — **destroys your data**                  |
| `make distclean`       | `clean` + remove the rootfs tree (needs sudo)                       |

`make` with no arguments builds `image` and `workspace`. The dependency
check runs automatically before every real target, as an order-only
prerequisite, so it never causes spurious rebuilds.

## Configuration

Override on the command line (`make SUITE=trixie MEM=8G qemu`) or edit the
top of the Makefile:

| Variable     | Default              | Meaning                                            |
| ------------ | -------------------- | -------------------------------------------------- |
| `SUITE`      | `testing`            | Debian suite; use `trixie` for stable              |
| `ARCH`       | `amd64`              | Target architecture                                |
| `MIRROR`     | `deb.debian.org`     | Debian mirror                                      |
| `IMG`        | `claustrum.erofs`    | Root filesystem image path                         |
| `EROFS_OPTS` | `-zlz4hc`            | mkfs.erofs options (try `-zzstd` or empty)         |
| `WS_IMG`     | `workspace.img`      | Workspace disk path                                |
| `WS_SIZE`    | `20G`                | Workspace disk size (sparse; grows as used)        |
| `DEVUSER` / `DEVPASS` | `dev` / `dev` | Guest user account                                |
| `ROOTPASS`   | `root`               | Guest root password                                |
| `MEM` / `CPUS` | `4G` / `2`         | VM resources                                       |
| `SSH_PORT`   | `2222`               | Host port forwarded to guest SSH                   |
| `HOST_PUBKEY`| first `~/.ssh/id_*.pub` | Host SSH key baked into the image for passwordless access |
| `DEV_PKGS`   | *(see Makefile)*     | Packages installed during provisioning             |

Change the default passwords if the VM will be reachable by anyone but you.

## The guest git server

The guest doubles as a small git server so Claude Code can work on real
repositories and you can pull its work back out over plain git. There is
no daemon involved — it's bare repositories on the workspace disk served
over the SSH connection that already exists:

```
/workspace/git/<name>.git   bare repos ("the server"), survive rebuilds
/workspace/src/<name>       working clones -- where Claude Code works
```

**Import a repository** (VM must be running):

```sh
make import REPO=https://github.com/user/project.git
```

The guest mirrors the URL into `/workspace/git/project.git` and makes a
working clone in `/workspace/src/project` whose `origin` is the local bare
repo. Inside the VM, Claude Code commits and pushes to that origin like any
other repo.

**Access it from the host:**

```sh
make clone NAME=project          # or manually:
git clone ssh://dev@localhost:2222/workspace/git/project.git
```

**Claude Code knows all of this already.** Provisioning bakes a
`claustrum-repos` skill into `/etc/skel/.claude/skills/`, which lands in the
dev user's `~/.claude/skills/` when the home directory is created on first
boot. The skill teaches the agent the layout above: where repos live, how to
create a working clone from a bare repo, to push to the local origin early
and often, never to push to external remotes, and what the read-only root
means for its work. So inside the VM you can just say "work on project" and
it takes it from there. One caveat: `/etc/skel` only populates *new* homes —
if your workspace disk predates the skill, copy it in once from inside the
guest: `cp -r /etc/skel/.claude/skills ~/.claude/`.

Host and guest are now two peers pushing/pulling through the same bare
repo — review Claude's commits on the host, push fixes back, and the
guest sees them with a `git pull`. Pushing back to the original upstream
(e.g. GitHub) is deliberately left to you, from the host, with your own
credentials: the sandbox never needs write access to the real remote.

**Passwordless access:** if you have an SSH key (`~/.ssh/id_ed25519.pub`
or similar), `make image` bakes it into `/etc/ssh/authorized_keys/dev` in
the immutable image — sshd in the guest is configured to read keys from
there, since the dev user's home doesn't exist until first boot. No key?
Everything still works with the account password, just with more typing.

## How the immutability works

The root disk is erofs, a read-only filesystem — there is no remount-rw
escape hatch. Everything that normally needs a writable root is handled at
build time or redirected:

- `/etc/machine-id` and the SSH host keys are baked in during provisioning,
  since they can't be generated at runtime.
- `/tmp`, `/var/tmp`, and `/var/log` are tmpfs (fresh on every boot); DHCP
  leases and resolver state live in `/run` as usual.
- The dev user's home is `/workspace/home/dev` on the writable disk. A
  `tmpfiles.d` entry creates it from `/etc/skel` on first boot, after the
  workspace disk is mounted.

Consequences worth knowing: `apt install` and Claude Code's auto-updater do
**not** work inside the guest — that's the point (provisioning sets
`DISABLE_AUTOUPDATER=1` so it doesn't try). Project-level installs (pip
venvs, `npm install` in a repo, cloned toolchains) work fine anywhere under
`/workspace` or `~`. To change the *system* — add a package, update Claude
Code — edit `DEV_PKGS` or the provisioning script and rebuild:

```sh
sudo make distclean && make
```

The workspace disk is never touched by `clean` or `distclean`, so your
checkouts and Claude Code credentials survive every rebuild.

## Troubleshooting

**`check-deps` says a tool is missing but the package is installed.**
Debian installs admin tools (`debootstrap`, `mkfs.erofs`, `mkfs.ext4`) in
`/usr/sbin`, which is not on a regular user's `PATH`. The Makefile appends
the sbin directories to `PATH` for its own recipes, so this should not
happen with the current version — if it does, check the package actually
ships the binary: `dpkg -L <package> | grep bin`.

**`/etc/initramfs-tools/modules: No such file or directory` during provisioning.**
Debian testing (forky) switched the kernel's default initramfs generator
from initramfs-tools to dracut, so the kernel package alone no longer pulls
initramfs-tools in. The Makefile pins `initramfs-tools` explicitly in
`DEV_PKGS`. If you hit this, your Makefile predates the fix — update it and
re-run `make provision` (the apt step is idempotent; apt will swap dracut
out for initramfs-tools if needed).

**`Failed to enable unit: Unit systemd-resolved.service does not exist`.**
Since Debian 12, `systemd-resolved` is a separate package. It's included in
`DEV_PKGS`; if you see this, your rootfs predates the fix — rebuild with
`sudo make distclean && make`.

**DNS fails during provisioning (npm step).** Installing systemd-resolved
replaces `/etc/resolv.conf` with a symlink that dangles inside a chroot.
The provisioning script restores a working resolv.conf after the apt step
and only re-creates the symlink at the very end. A leftover dangling
symlink from an interrupted run is also handled on re-run.

**`claude: command not found` after provisioning.** The npm package
delivers a native binary through per-platform optional dependencies plus a
postinstall step that links it into place. If you customized the install,
make sure you did **not** pass `--ignore-scripts` and that optional
dependencies are enabled — either breaks the install. Provisioning runs
`claude --version` and fails loudly if the binary is missing. Debian
testing's Node satisfies the npm package's engine requirement, and even on
older Node the install only prints an `EBADENGINE` warning — the installed
binary doesn't use the system Node at runtime.

**`mkfs.erofs: unknown compression` or similar.** Your erofs-utils build
lacks lz4hc. Build with `EROFS_OPTS=-zzstd` or `EROFS_OPTS=` (no
compression). `check-deps` warns about this.

**Boot hangs after the kernel loads.** Make sure you rebuilt the image
after any provisioning change — the initramfs must contain the erofs
module (provisioning adds it to `/etc/initramfs-tools/modules`). Kernel
messages appear on the serial console because of `console=ttyS0`.

**QEMU is very slow.** You're on TCG. See the `/dev/kvm` note under
Requirements.

## Layout

```
Makefile            the whole build
rootfs/             debootstrapped tree (build artifact, root-owned)
claustrum.erofs     immutable root image        -> /dev/vda, mounted ro at /
workspace.img       writable workspace image    -> /dev/vdb, mounted at /workspace
vmlinuz, initrd.img kernel + initramfs extracted from the rootfs for -kernel boot
```

## Security notes

The guest is a sandbox, not a vault: QEMU user-mode networking gives it
outbound internet access, and the workspace disk is shared state that
persists between runs — including your Claude Code credentials in
`~/.claude`. The immutable root means the agent can't persist changes to
the OS even with permissions fully relaxed, but anything in `/workspace`
is fair game; treat that disk accordingly.

---

*One more thing about the name: the claustrum is also a thin, enigmatic
sheet of neurons in the brain that some neuroscientists have proposed as a
coordinator of consciousness. Make of that what you will.*
