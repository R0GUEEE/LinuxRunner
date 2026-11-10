# Changelog

User-visible changes follow Added / Changed / Fixed / Known Issues.

## [1.1.4] — 2026-11-10 (Build 908)

### Added

- **Import Rootfs** (Settings › Linux Environment): bring your own ARM64 Linux userspace.
  Accepts `.tar`, `.tar.gz`, `.tgz`, `.tar.xz` and `.txz` up to 512 MB, shows the size and
  SHA-256 before importing, and unpacks through the existing verified import path (private
  copy, hash of those exact bytes, entry-budgeted extraction, no traversal).
  The distribution name, version, package manager and shell are read from `/etc/os-release`
  and from the binaries present, so Updates and Quick Commands work on the new environment.
  An archive wrapped in one top-level folder is detected and re-imported without it; anything
  that is not a root filesystem is rolled back with an explanation instead of being kept.

### Changed

- Version 1.1.4 (908).

## [1.1.3] — 2026-11-10 (Build 907)

### Added

- **Updates** (Storage & Maintenance): queries the active distribution's own updater (`apt`,
  `pacman`, `dnf`, `apk`) through the bundled package script, lists upgradable packages with
  installed → available versions, and offers **Upgrade All** and **Refresh Package Lists** in a
  terminal so the package manager's own confirmation still guards the transaction. SteamOS is
  inspection-only and says so.
- **Services**: lists `/etc/init.d` and `/etc/rc.d/init.d` scripts from the environment and runs
  start/status/restart/stop through the terminal. States plainly that this runtime has no init
  system, so nothing starts these at boot.
- **System Logs**: read-only browser for the environment's `/var/log`, newest first, with a bounded
  64 KB tail view, copy/select and share.

### Changed

- Version 1.1.3 (907).

## [1.1.2] — 2026-11-10 (Build 906)

### Added

- **System Health** (Settings › Linux Environment): runtime, backend, guest process count,
  app memory and free storage at a glance, the largest guest processes by memory, per-environment
  rows, recent warnings and errors, and an **inventory report** export (Markdown) covering device,
  runtime, environments, processes and failures.
- **Quick Commands**: saved `/bin/sh -c` one-liners seeded per package manager (update, disk,
  memory, processes, largest directories, ports, log tail), with add/edit/delete/reorder. Each run
  opens a terminal through the same path as the application launcher.
- **Startup command editor** in Terminal & Keyboard for the boot command and login shell, replacing
  the legacy storyboard field as the only way to set them.
- Storage: **Remove Downloaded Installer Packages** reclaims the package cache the Arch installer
  otherwise keeps forever, guarded so it never runs during an install.

### Changed

- Version 1.1.2 (906).

## [Unreleased] — LinuxRunner 1.1.1 fork maintenance

Audit and compatibility pass on top of 1.1.1 (905). Full detail in
[docs/BUG-AUDIT.md](docs/BUG-AUDIT.md) and [docs/IOS27.md](docs/IOS27.md).

### Fixed

- Interpreter: `tmpfs` reads with the file offset past EOF copied from outside the
  host heap; a negative `lseek(SEEK_SET)` turned a guest write into host heap
  corruption. A failed `SIGEV_THREAD_ID` timer creation left the global pid lock
  held, wedging `fork`/`wait4`/`kill` for the whole guest.
- Guest path strings that fill the 4 KiB buffer without a NUL are now rejected
  instead of being used as C strings; `readv`/`writev` reject oversized lengths and
  vectors as Linux does.
- Terminal: an exactly-full argument buffer wrote one byte past `argv[4096]`.
- Clipboard: `/dev/clipboard` reported UTF-16 lengths for a UTF-8 buffer (non-ASCII
  pastes were cut short) and writing invalid UTF-8 silently cleared the user's
  clipboard.
- Location: `/dev/location` could report `0,0` after a concurrent open, and
  authorization granted after launch never started updates.
- Audio: stopping the desktop leaked the guest sound socket and could free the ring
  buffer under an in-flight render callback.
- Installers: the archive SHA-256 no longer runs on the main actor, so the UI and
  Cancel stay responsive while Debian and Arch archives are verified.

### Added

- `PrivacyInfo.xcprivacy` with the required-reason API declarations.
- Documented iOS / iPadOS 27 support, including the scene life cycle requirement and
  the external-display accessory change (`docs/IOS27.md`).
- GitHub Actions workflow that builds an unsigned IPA on `macos-26`.

### Changed

- StikDebug hand-off uses `UIApplication.open` only; `canOpenURL:` is deprecated in
  iOS 27.

## [1.1.1] — 2026-11-08 (Build 905)

Full release notes: [docs/releases/v1.1.1.md](docs/releases/v1.1.1.md).

### Added

- Redesigned Distributions tab: installed cards with each distribution's own logo, an Add a Distribution grid (2 columns on iPhone, 4 on iPad) and a simpler detail screen.
- Redesigned Settings: header with version and active distribution, grouped categories (General, Desktop & Display, Graphics & Performance, Input & Controls, Linux Environment, Storage & Maintenance, Advanced, About) with colored icon rows. All existing settings and saved preferences are kept.
- Installation screensaver for OLED screens: after 3, 4 (default) or 5 minutes without a touch during an installation, a dim, slowly moving status on black. Any touch, completion or failure dismisses it; installations continue.
- SteamOS ARM64 (Experimental) in Setup and Distributions: **Install** downloads Valve's SteamFrame recovery image (3.8 GB, resumable) from Valve's server, checks its published SHA-256, unpacks only its root partition and reads that Btrfs filesystem natively (zstd, checksummed metadata), adding two pinned Arch Linux ARM display packages (x11vnc, libvncserver). No prepared archive or helper system is needed; the download is removed afterwards. Prepared archives (community PR #21) remain supported. Not official SteamOS support; Steam games are not supported.
- Termux-like terminal on iPhone: sharp text, true black, two-row key bar, clipboard. Live desktop preview on Home. Desktop control pill and compact landscape pill.

### Changed

- Home: Applications section removed; iPad quick tiles are wide cards.
- Plasma display bridge sends only changed screen tiles (about 7x less data per frame) and paces pointer motion to captured frames.
- Long installations (Kali tools) no longer stop after one hour; they fail only after 45 minutes without progress.
- Storage measurement pauses while a desktop is visible (community PR #18).
- Guarded shared-memory desktop capture for Arch and SteamOS with crash-safe cleanup (community PR #20).
- Interpreter memory: bounded translation cache on devices, released discarded pages, guest memory budget (community PR #26).

### Fixed

- Plasma panel clock (timerfd TFD_TIMER_CANCEL_ON_SET).
- Fedora desktop: empty Applications menu and blank panel icons; desktop start no longer repeats a 14-second package check.
- Home showed Stopped while the desktop was running.
- Blurry terminal text.
- Virtual display timing and vblank events (community PR #19).

### Known Issues

- SteamOS ARM64 is experimental and needs about 19.4 GB free while installing, 8.9 GB afterwards.
- KDE Plasma menus update slowly (about 1 frame per second when hovering); Xfce and the LinuxRunner desktop are faster.
- Kali tool installation remains slow (about 50 ms per unpacked file).

## [1.1.0] — 2026-11-01 (Build 900)

### Added

- External desktop output with compatible wired/AirPlay receivers and an iPhone touchpad control surface.
- Metal-backed virtual GPU integration through Mesa/virgl, virglrenderer and ANGLE.
- LXQt, Arch Enlightenment, Wayfire and experimental Arch Hyprland desktop selection/installation.
- Optional iOS ARM64 JIT build and execution-status/activation controls, with interpreter fallback.
- Host network diagnostics, Linux interface/address/route compatibility and per-environment file sharing.

### Changed

- ARM64 NEON comparisons/pairwise operations, exclusive stores, memory dispatch and dirty-page filtering.
- JIT register checkpoint handling and ARMv8 AES/SHA translation; validated PMULL, SHA1/SHA2 and CRC32 capability reporting.
- Desktop controls, landscape 960 × 540 defaults, resolution preferences and reconnection behavior.
- Graphical application launch contexts and compatibility, including maintainer-tested Vesktop functionality.
- Documentation, requirements, installation and screenshots for the major release.

### Fixed

- Vector RBIT incorrectly behaving as NOT and JIT out-of-range LDUR guest-PC corruption.
- signalfd poll/epoll readiness, concurrent close and shared memfd mapping-growth cases covered by runtime contracts.
- Batched/malformed netlink route replies and fabricated/empty network reports.
- Wayland application launch context and Arch Wayfire GPU startup integration.
- Hyprland's duplicate pointer overlay and saved Fit preferences retaining an unwanted portrait size.
- Release stripping removing dynamically resolved EGL exports from the GPU-enabled executable.

### Known Issues

- Hyprland is experimental, requires at least 8 GB RAM and Arch, and can need Retry on first launch. Metal is recommended.
- Metal must be explicitly selected and followed by a full app restart. GPU/API coverage is incomplete.
- JIT activation is restricted by the host platform and can make short programs slower.
- Alpine desktop coverage is limited; Debian Enlightenment and Arch Plasma are not validated working paths.
- Bluetooth networking is unsupported. Receiver-specific external-output behavior and older OS compatibility vary.
- iOS termination ends Linux processes; demanding applications can exceed memory limits.

## [1.0.1] — 2026-10-27

### Added

- iPad desktop adaptations: window-aware initial display sizing, hardware-keyboard desktop shortcuts and larger viewer-frame support, alongside the shared touch/pointer interface. Tested on a physical iPad.
- Arch Linux ARM installation from signed packages, `pacman` integration and an experimental Openbox desktop with LXQt Panel and PCManFM-Qt.
- Telegram Desktop compatibility on Arch Linux ARM, tested by the maintainer with login, sending messages and calls on build 897.
- A unified **Set Up Linux…** workflow for new installations and configuration of existing environments.
- Arch package-state diagnostics and signed cached-package/ownership recovery through the package-management path and Repair Center.

### Changed

- Arch desktop defaults now use a named PCManFM-Qt profile and dedicated visible LXQt panel configuration while preserving existing user settings.
- Desktop readiness checks require usable component windows and a submitted viewer frame; startup diagnostics retain relevant Qt platform errors.
- IPA packaging now includes an ad-hoc signature and installer-friendly ZIP layout. Apple signing/provisioning is still required for ordinary device installation.
- Installation, distribution, compatibility and troubleshooting documentation now covers iPhone, iPad and all three distributions.

### Fixed

- Arch terminal compatibility for the termios2 operations required by its shell environment.
- Qt desktop/application launch context so managed launches inherit the active user's X11 display and authorization.
- Reopening a live desktop now reuses its existing session/viewer rather than rejecting re-entry.
- Invalid or obsolete Arch package-recovery state, including validated reconciliation of orphaned GCC ownership, without bypassing signature checks.
- Desktop panel/surface failure handling so a repeatedly crashing component does not falsely leave the desktop marked ready or end unrelated applications.
- ARM64 vDSO executable mapping and Linux filesystem/syscall compatibility gaps covered by the retained regression evidence.

### Known Issues

- Arch desktop and Metal acceleration remain experimental. Arch Plasma and Wayland sessions are unavailable; some Arch GTK/glycin applications encounter write-seal compatibility gaps.
- Application compatibility still depends on distribution, package version and device resources.
- Exact tested device/OS and artifact identities should accompany compatibility reports.
- An earlier iPhone 11/iOS 17 app-launch black-screen report remains unresolved.
- Demanding applications can be slow or exceed platform memory limits. Background suspension/termination can stop Linux processes.

## [1.0.0] — 2026-10-25

### Added

- First public release of the iPhone application, with ARM64 Linux instruction interpretation and a Linux userspace compatibility layer.
- Debian and Alpine environments, terminal, Linux accounts, package management and LinuxRunner Desktop.
- Experimental Debian KDE Plasma and Metal graphics support, with application compatibility limitations.
- Installation progress for account tools, desktop components and KDE Plasma, including measured percentages where available, actionable errors and retry.
- Keep Screen Awake During Operations, Settings icons and third-party font/terminal notices.

### Changed

- Account-tool preparation reuses recent package lists, retries outdated lists and checks installed tools before reporting success.
- Public versioning and LinuxRunner branding replaced the earlier internal version/name in user-facing release information.

### Fixed

- An account-tools preparation failure could appear to finish without effect when its installer had not started.

[1.0.1]: https://github.com/mxhm11cr/LinuxRunner/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/mxhm11cr/LinuxRunner/releases/tag/v1.0.0
