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
  and Claude Code itself preinstalled from Anthropic's signed apt
  repository.
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
sudo apt install debootstrap qemu-system-x86 qemu-utils e2fsprogs erofs-utils
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
| `make base`            | debootstrap Debian once, cache it as `base-<suite>.erofs`           |
| `make provision`       | overlay layer on the base: kernel, dev tools, users, Claude Code    |
| `make reprovision`     | wipe only the provision layer and redo it (cached base is reused)   |
| `make install PKGS=..` | apt-install packages into the system image (incremental repack)     |
| `make image`           | Pack the rootfs into the read-only erofs image + extract kernel     |
| `make workspace`       | Create the writable workspace disk (only if it doesn't exist)       |
| `make qemu`            | Boot the VM (serial console, virtio disks/net, SSH on host :2222)   |
| `make serial-attach SERIAL_DEV=..` | Hot-plug a serial device into the running guest (Ctrl-C unplugs) |
| `make serial-log`      | Follow the serial traffic log (both directions, hex + text)         |
| `make ssh`             | SSH into the running VM as the dev user                             |
| `make import REPO=url` | Mirror a repo into the guest git server + create a working clone    |
| `make repos`           | List repositories hosted in the guest                               |
| `make clone NAME=n`    | Clone a guest repo onto the host over SSH                           |
| `make put SRC=path`    | Copy host files/dirs into the guest (default `/workspace/files/`)   |
| `make get SRC=path`    | Copy guest files/dirs back to the host (absolute guest path)        |
| `make pull FILE=path`  | Like `get`, but the path is relative to `/workspace`                |
| `make clean`           | Remove the root image, kernel, and initrd (workspace untouched)     |
| `make convert-workspace` | One-time migration of an old raw `workspace.img` to qcow2         |
| `make clean-workspace` | Delete the workspace disk — **destroys your data**                  |
| `make distclean`       | `clean` + remove the overlay layers and the cached base image       |

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
| `WS_IMG`     | `workspace.qcow2`    | Workspace disk path (qcow2)                        |
| `WS_SIZE`    | `64G`                | Workspace virtual size (qcow2 grows as used)       |
| `DEVUSER` / `DEVPASS` | `dev` / `dev` | Guest user account                                |
| `ROOTPASS`   | `root`               | Guest root password                                |
| `MEM` / `CPUS` | `16G` / half of host cores | VM resources                                |
| `SSH_PORT`   | `2222`               | Host port forwarded to guest SSH                   |
| `HOST_PUBKEY`| first `~/.ssh/id_*.pub` | Host SSH key baked into the image for passwordless access |
| `DEV_PKGS`   | *(see Makefile)*     | Packages installed during provisioning             |

Change the default passwords if the VM will be reachable by anyone but you.

## Sharing serial devices, on demand

The guest's second serial port (`/dev/ttyS1`) always exists: QEMU exposes
it as a TCP socket listening on `localhost:7777` (`SERIAL_PORT`). Nothing
is decided at boot — you plug devices in and out of a *running* VM:

```sh
make serial-attach SERIAL_DEV=/dev/ttyUSB0 SERIAL_BAUD=115200
```

runs in the foreground, streaming every byte in both directions to your
terminal as timestamped hex+text (`>` guest-to-device, `<` device-to-
guest) and appending to `serial-tap.log` (`make serial-log` follows it
from another terminal). **Ctrl-C is the unplug**; re-run to re-plug,
swap `SERIAL_DEV` to plug a different adapter — no VM restart, ever.

Caveats: while detached, guest writes to `ttyS1` are discarded and reads
block — that's the semantics of an unplugged cable. The relay pins the
physical port at `SERIAL_BAUD`; guest termios changes on `ttyS1` don't
reach the real adapter. The listener binds to 127.0.0.1 only, so
nothing off-host can reach it. Needs `socat`
(checked at attach time, not a base requirement). The guest `dev` user is
in `dialout`, so no sudo is needed to open `ttyS1`.

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

**Moving loose files** works the same way as repos, over the existing SSH
channel: `make put SRC=./data.csv` drops files into `/workspace/files/`
(or anywhere with `DEST=`), and `make pull FILE=files/out.pdf`
(or `make get` with an absolute guest path) brings results back. Directories work too (`scp -r`). The baked-in skill
tells Claude Code to look in `/workspace/files` when you mention having
shared a file, and to leave deliverables under `/workspace` and tell you
the path.

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

## Build caching: erofs all the way down

The build has two stages, and the cache boundary between them uses the same
mechanism as the final VM: an immutable erofs layer with a writable layer
on top.

Stage 1 (`make base`) runs debootstrap once and packs the pristine result
into `base-<suite>.erofs`. That file *is* the cache — the scratch directory
is deleted afterwards. Stage 2 (`make provision`) loop-mounts the base
read-only and stacks an overlayfs upper directory on it; every provisioning
write (apt packages, Claude Code, config) lands in `layers/upper/`, and the
base image is never modified. The final root image is packed from the
merged view.

This makes redoing provisioning cheap and *clean*:

```sh
make reprovision      # drop layers/upper, re-run provisioning, repack image
```

No new debootstrap, no re-downloading the Debian base — and unlike
re-running provisioning in a shared tree, there's no residue: appends to
files like `/etc/environment` can't accumulate duplicates because every
reprovision starts from the untouched base layer. Iterate on `DEV_PKGS`,
the MOTD, or the Claude Code install with a minutes-long loop instead of a
full rebuild. `make distclean` is only needed when you want a *newer
Debian base* (e.g. testing has moved on), since the cached base is frozen
at whatever debootstrap fetched.

Note the host mounts (loop + overlay) require sudo and a kernel with erofs
support — `check-deps` warns if the erofs module looks absent.

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
`DISABLE_AUTOUPDATER=1` so it doesn't try). Adding a package is done from
the host instead: `make install PKGS="htop strace"` chroots into the
overlay layers, apt-installs, and repacks the image — an incremental
operation, no reprovision needed. Packages added this way persist across
image rebuilds but live only in the provision layer, so also add them to
`DEV_PKGS` if they should survive a `make reprovision`. Project-level installs (pip
venvs, `npm install` in a repo, cloned toolchains) work fine anywhere under
`/workspace` or `~`. To change the *system* — add a package, update Claude
Code — edit `DEV_PKGS` or the provisioning script and rebuild:

```sh
sudo make distclean && make
```

The workspace disk is never touched by `clean` or `distclean`, so your
checkouts and Claude Code credentials survive every rebuild.

The workspace is a qcow2 image: 64G virtual, but on disk it only occupies
what's actually written. Growing it later is two steps with no data loss:
`qemu-img resize workspace.qcow2 128G` (VM off), then boot — a
`workspace-grow` service in the guest runs `resize2fs` on every boot and
expands the filesystem to fill the disk (a no-op otherwise). Migrating
from the old raw format: shut the VM down and run `make convert-workspace`
— it converts `workspace.img` to `workspace.qcow2`, resizes to `WS_SIZE`,
and keeps the raw original untouched until you delete it yourself.

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
`DEV_PKGS`; if you see this, your build predates the fix — `make reprovision`.

**DNS fails during provisioning (npm step).** Installing systemd-resolved
replaces `/etc/resolv.conf` with a symlink that dangles inside a chroot.
The provisioning script restores a working resolv.conf after the apt step
and only re-creates the symlink at the very end. A leftover dangling
symlink from an interrupted run is also handled on re-run.

**`claude: command not found` after provisioning.** Claude Code is
installed from Anthropic's signed apt repository
(`downloads.claude.ai/claude-code/apt/stable`); provisioning verifies the
release key's published fingerprint before trusting it and asserts
`claude --version` so a broken install fails the build loudly. Earlier
revisions installed via npm and were repeatedly broken by npm v12's new
install-script blocking (the package's postinstall — which links the
native binary into place — was silently skipped, leaving a successful-
looking install with no binary). If you're on the npm variant and hit
this, `make reprovision` with the current Makefile. To get a newer Claude
Code later, bump the image: it's one `make reprovision` away, or switch
the repo line to the `latest` channel in the provisioning script.

**`mkfs.erofs: unknown compression` or similar.** Your erofs-utils build
lacks lz4hc. Build with `EROFS_OPTS=-zzstd` or `EROFS_OPTS=` (no
compression). `check-deps` warns about this.

**Boot hangs after the kernel loads.** Make sure you rebuilt the image
after any provisioning change — the initramfs must contain the erofs
module (provisioning adds it to `/etc/initramfs-tools/modules`). Kernel
messages appear on the serial console because of `console=ttyS0`.

**`claude` prints nothing and spins at 100% CPU.** Three guest-specific
causes, all fixed in the current Makefile; triage with `claude --version`
(does the binary run at all?) and `ping -c1 1.1.1.1` / `getent hosts
api.anthropic.com` (is networking up?).
*CPU model:* QEMU's default `qemu64` CPU hides modern instruction-set
features from a binary that assumes them — provisioning's `claude
--version` check runs on the *host* CPU in a chroot, so it can't catch
this. The Makefile now passes `-cpu max` (all host features under KVM,
all emulated features under TCG). Takes effect on the next `make qemu`,
no rebuild.
*Guest networking:* earlier revisions had a mismatch between
`net.ifnames=0` on the kernel command line (interface named `eth0`) and a
networkd match of `Name=en*` — the match is now `eth* en*`. Needs
`make reprovision`.
*Telemetry:* upstream issues tie renderer CPU spins to failing telemetry
exports; the image sets `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` so
the sandbox skips telemetry, update checks, and error reporting entirely.

**`claude` misrenders or spins only on the serial console.**
Serial lines report a 0x0 terminal size and getty defaults `TERM=vt220`;
Claude Code's full-screen renderer can spin on that degenerate geometry. A
login-shell snippet (`/etc/profile.d/serial-console.sh`) now sets
`TERM=xterm-256color` and a 140x40 fallback size on ttyS* logins. On an
image predating the fix: `stty rows 40 columns 140; export
TERM=xterm-256color` and retry — or better, use `make ssh`, which
negotiates real terminal dimensions and is the recommended way to run
interactive claude sessions anyway.

**QEMU is very slow.** You're on TCG. See the `/dev/kvm` note under
Requirements.

## Layout

```
Makefile            the whole build
base-testing.erofs  cached pristine debootstrap result (stage 1 output)
layers/upper/       overlayfs upper dir: everything provisioning added
layers/{lower,work,merged}/  mountpoints used during builds
claustrum.erofs     final root image (base + provision merged) -> /dev/vda, ro at /
workspace.qcow2     writable workspace disk     -> /dev/vdb, mounted at /workspace
vmlinuz, initrd.img kernel + initramfs extracted from the image for -kernel boot
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
