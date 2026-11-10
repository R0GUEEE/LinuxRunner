# Bug audit — November 2026

Static audit of LinuxRunner 1.1.1 (build 905) across the Objective-C UI layer, the
Swift layer and the C emulator core. Findings are ordered by severity inside each
section; every one was read in context before being written down. Items marked
**fixed** are patched in this branch and were rebuilt by CI afterwards.

The audit looked for defects a user or a guest program can actually reach: host
memory corruption, guest-triggerable deadlocks, data loss, and UI-blocking work.

## Emulator core (C)

| # | Severity | Where | Problem | Status |
| --- | --- | --- | --- | --- |
| C1 | critical | `fs/tmp.c` `tmpfs_read` | `inode->stat.size - fd->offset` is unsigned; reading with the offset past EOF (`lseek(fd, N, SEEK_END)` or `pread`) wrapped the subtraction, skipped the EOF clamp and `memcpy`'d up to 4 GiB from outside the host heap object. Guest-triggerable crash of the whole emulator, or disclosure of neighbouring heap into the guest buffer. | fixed |
| C2 | high | `fs/generic.c` `generic_seek`, `fs/tmp.c` `tmpfs_write` | `SEEK_SET` stored a negative guest offset without validation (Linux returns `EINVAL`), producing `fd->offset = SIZE_MAX`; the write path's `offset + bufsize` then wrapped, skipped the resize, and wrote guest data before `file_data`. Guest-controlled heap corruption. | fixed |
| C3 | high | `kernel/time.c` `sys_timer_create` | `pid_get_task()` failure returned `_EINVAL` while still holding the global `pids_lock`. One `timer_create(CLOCK_MONOTONIC, &sigev_with_bogus_tid, ...)` blocks every later `fork`, `wait4`, `kill`, `tgkill` and `/proc` lookup forever. | fixed |
| C4 | medium-high | `kernel/user.c` `user_read_string` | Returned success when the guest string filled the 4096-byte buffer without a NUL, leaving callers (`openat`, `execve`, `chdir`, `setxattr`, …) to walk past a stack buffer. Now reports failure unless a terminator was copied. | fixed |
| C5 | medium | `kernel/time.c` `SIGEV_THREAD_ID` | The validated `sigev.tid` was discarded and the timer targeted the thread-group leader, so per-thread timers fired on the wrong thread. | fixed |
| C6 | medium | `kernel/fs.c` `read_iovec` | No `IOV_MAX` cap (a `readv` with `iovcnt = ~0u` allocated 68 GiB before validation) and 64-bit guest lengths were truncated to 32 bits instead of rejected, silently shortening writes where Linux returns `EINVAL`. | fixed |
| C7 | low | `kernel/uname.c` `sys_sysinfo` | Writes the struct at `+8` when the first 8 bytes of the guest buffer happen to look like a stack canary, so `uptime`/load averages are never written. Inherited upstream heuristic. | open |
| C8 | low | `fs/proc.c`, `kernel/fs.c`, `fs/sock.c` | Assorted errno/normalisation deviations (negative `pread` offset on procfs, `lseek` overflow tested after the offset was already stored, `getsockopt` allocating the guest's full `optlen`). No memory-safety impact. | open |

C1–C6 are inherited from upstream iSH; C6's 64-bit iovec conversion is specific to
this fork's ARM64 build.

## Objective-C UI layer

| # | Severity | Where | Problem | Status |
| --- | --- | --- | --- | --- |
| O1 | high | `app/Terminal.m` `convertCommand:toArgs:limitSize:` | `*++p = '\0'` runs past the end of the stack `argv[4096]` when the arguments fill the buffer; reachable from the user-writable guest preference `/proc/ish/defaults/boot_command`, which `AppDelegate` passes through unvalidated. | fixed |
| O2 | high | `app/PasteboardDevice.m` `get_data` | Reported `NSString.length` (UTF-16 units) as the length of a UTF-8 buffer, so every non-ASCII paste through `/dev/clipboard` was truncated or cut mid-sequence. | fixed |
| O3 | medium | `app/PasteboardDevice.m` `clipboard_write_sync` | `initWithBytes:length:encoding:` returns nil for invalid UTF-8 and the nil was assigned to `UIPasteboard.string`, clearing the user's clipboard while reporting success. Now returns `EINVAL`. | fixed |
| O4 | medium | `app/LocationDevice.m` `+instance` | A `__weak` static plus a racy double-check let concurrent openers of `/dev/location` receive nil; `latest` then formatted as `+0.000000,+0.000000`. Also `dispatch_sync` to the main queue could deadlock when first opened from the main thread. | fixed |
| O5 | medium | `app/LocationDevice.m` | Only implemented the deprecated `didChangeAuthorizationStatus:`, so authorization granted after first launch never started updates on modern iOS. Added `locationManagerDidChangeAuthorization:`. | fixed |
| O6 | medium | `app/LinuxRunner/AudioBridge.m` `readLoop` | If `-stop` ran between `connect()` and the socket store, `stop` saw `-1`, the loop broke on `_stopped` without closing the descriptor, and the guest sound server kept a half-open peer. One leaked fd per desktop session. | fixed |
| O7 | medium | `app/LinuxRunner/AudioBridge.m` render block | Captured the bridge `__unsafe_unretained`; `AVAudioEngine -stop` does not join an in-flight render callback, so teardown could free `_ring` under it (EXC_BAD_ACCESS in `render:`). Now a zeroing weak reference with a silence fallback, and `dealloc` detaches the node first. | fixed |
| O8 | low | `app/UserPreferences.m` | `strdup()` of a nil lookup result (unknown preference name) and an unchecked `malloc`. | open |
| O9 | low | `app/FileProvider/FileProviderExtension.m` | `substringToIndex:NSNotFound` raises on a path without a slash; `return nil` from `BOOL` methods. Latent (callers pass absolute paths) but the extension is not built in the ARM64 scheme. | open |
| O10 | low | `app/LinuxRunner/Diagnostics.swift`, `app/FontPickerViewController.m`, document pickers | Deprecated APIs still in use: `UIButton.contentEdgeInsets` (iOS 15), `UIDocumentPickerMode*` and `initWithDocumentTypes:inMode:` (iOS 14), `keyCommandWithInput:modifierFlags:action:discoverabilityTitle:` (iOS 13). None of them is removed yet. | open |

## Swift layer

| # | Severity | Where | Problem | Status |
| --- | --- | --- | --- | --- |
| S1 | high | `DebianInstaller.swift`, `ArchInstaller.swift` | `Self.sha256(archive)` ran inline on the main actor (the enclosing `Task` inherits `@MainActor`), hashing the just-assembled 100–200 MB archive with the UI, the Cancel button and the progress card all frozen. | fixed |
| S2 | high | `DebianInstaller.swift:112,119`, `ArchInstaller.swift:284,291` | The C assembly/import callbacks fire once per archive entry (tens of thousands of times) and each one spawns a fresh `Task { @MainActor }` to update progress, which republishes `LongTaskCenter.entries` and rewrites the iOS 26 Live Activity progress. Stutters the whole install. Fedora/Kali/SteamOS already throttle the same path. | open |
| S3 | high | `SteamOSInstaller.swift` | Stale `NSURLSessionDownloadTaskResumeData` is written back on failure and reused on the next attempt, so one poisoned `.resume` file makes every retry fail identically, with no in-app way to clear it. | open |
| S4 | high | `ManagerView.swift` `DesktopFileSharingDestination` | A second `EnvironmentManager` is created as `@StateObject`; its `persist()` rewrites the whole catalog from a stale snapshot, dropping `installationState`/`distributionID`/availability fields written by the primary one. | open |
| S5 | medium | `ArchInstaller.swift` | The Arch package cache under `downloads/archlinuxarm-aarch64` is never pruned and is not covered by the in-app storage cleanup, so it grows across retries and releases. | open |
| S6 | medium | `LongTaskCenter.swift` `end(_:success:message:)` | Returns early when the 20-entry cap already evicted the token, leaving the `BGContinuedProcessingTask` uncompleted and the background assertion leaked. | open |
| S7 | medium | `Diagnostics.swift` | `installer()` consumes two slots from the same 256-slot semaphore and does a synchronous disk append for failures, so exactly the records needed for a post-mortem are dropped under load. | open |
| S8 | medium | `Change`/`SetupWizard.swift`, `AppStoreView.swift` | File reads, manifest SHA-256 and whole-catalog JSON decoding happen inside SwiftUI `body` evaluation, repeated on every progress publish. | open |
| S9 | medium | `BluetoothSerialView.swift` | `ForEach(links.indices, id: \.self)` over an array that shrinks on a disconnect notification is the classic SwiftUI index-out-of-range path. | open |
| S10 | low | `ManagerView.swift` (file browser), `AppStoreView.swift` (poll timer), `LongTaskCenter.swift` (screensaver window set) | Missing refresh generation token, missing `deinit { timer?.invalidate() }`, and an ever-growing `Set<ObjectIdentifier>` of windows. | open |

Checked and found correct, for the record: archive extraction is fd-relative and
enforces `..`/symlink/size limits in `DebianBootstrap.c`; every download verifies
size *and* SHA-256 of the exact bytes it imports; the Fedora/Kali resumable download
validates `Content-Range` and rejects mirror-ignored ranges; the Arch signing-key
parser bounds-checks every packet and verifies the signature against a pinned
fingerprint; no SwiftUI state is written off the main actor; the MRC/ARC memory
management in the terminal and framebuffer path is balanced.

## Guest graphics path (Metal bridge + virtio-gpu)

This is the largest unauthenticated guest→host surface in the fork and it is entirely
new code — upstream iSH has none of it. `fs/gpu.c`'s ioctl dispatcher and `fs/drm.c`'s
handle/mmap/event paths were hammered and held up; what follows is what did not.

| # | Severity | Where | Problem | Status |
| --- | --- | --- | --- | --- |
| G1 | high | `app/LinuxRunner/GuestMetalBackend.h` `LRGuestMetalUniformBlocks` | Formed `reflection = p.blocksData.bytes` and dereferenced it before the `!p` check, so a program object without reflection state means a NULL read in the host process. | fixed |
| G2 | medium-high | `fs/drm.c` `add_fb` | `pitch < width * 4` was a 32-bit multiply: a `width ≥ 0x40000000` wrapped it, so an `ADD_FB2` with `pitch = 4` and a huge declared width passed, and the KMS bridge then read `min(width, screen_width) * 4` bytes out of a 4-byte-stride mapping. | fixed |
| G3 | low | `graphics/virgl_host.c` resource table | `count = handle * 2 + 64` in 32-bit; on wrap `count < backing_count` and the `memset` length underflows. ~2 billion resource creations to reach — guarded anyway. | fixed |
| G4 | medium | `fs/drm.c` `virgl_transfer` | `VIRTGPU_TRANSFER_*` forwards `stride`, `layer_stride`, `offset` and all six box fields to virglrenderer with no validation against the resource size, and `layer_stride` is narrowed to 32 bits. Every other ioctl in that file validates; this one delegates the safety of a host-memory copy to the dependency. | open |
| G5 | medium | `GuestMetalBackend.h` instance attributes | The divisor/value packet is sticky context state, never cleared on program change, delete or resize — a later non-instanced draw silently reuses stale instance data. | open |
| G6 | medium-low | `graphics/guest_uniforms.inc` | The UBO packet is assembled into a fixed scratch buffer before the kernel validates block sizes; only the shader compiler's reflection limits keep it in bounds today. | open |
| G7 | low | `GuestMetalBackend.h` `READ`/`READ_REGION` | Skip the `LRGuestResidentRelease` that every sibling transfer calls, so `glReadPixels` while a resident target is bound returns stale frame data or a spurious `EINVAL`. | open |
| G8 | low | `fs/gpu.c`, `guest_gl_subset.c` | `-EAGAIN` from the draw path (main-thread guard) reaches the guest as `GL_INVALID_OPERATION`, indistinguishable from a genuinely illegal call. | open |

Verified clean in the same pass: `fs/gpu.c`'s `r->bytes` pinning and interior
`offset`/`bytes` validation, the MRT header re-check after the body copy (closes the
check-then-copy TOCTOU), the transfer-buffer reserve/commit unwind, `create_dumb`'s
64-bit sizing with sealed memfds, `drm_mmap`'s window validation, the vblank/page-flip
event budget, the framebuffer refcount around `CLOSEFB` while scanning out, the
triple-buffered framebuffer upload (no `replaceRegion` against a texture with a live
command buffer), and the shader-reflection writers (every array write is limit-checked
inside a `try` that turns an overrun into a failed link).

## iOS 27

Covered separately in [IOS27.md](IOS27.md): scene life cycle already adopted, the
external-display accessory path already present behind SDK guards, `canOpenURL:`
deprecation removed, and a privacy manifest added.
