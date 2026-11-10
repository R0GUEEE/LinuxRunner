# iOS / iPadOS 27 support

Status: **builds and runs on iOS 27** from a CI build made with Xcode 26.6 and the
iPhoneOS 26.5 SDK. This document records what was checked, what changed, and what
still depends on an Xcode 27 SDK that is not available on GitHub-hosted runners.

## Build and runtime matrix

| Item | Value |
| --- | --- |
| Deployment target | iOS 15.0 (`IPHONEOS_DEPLOYMENT_TARGET`) |
| SDK used by CI | iPhoneOS 26.5 (Xcode 26.6, build 17F113) |
| Architectures | `arm64` only |
| Runtime on iOS 27 | supported: the app is built with an older SDK than the OS it runs on, which iOS always permits |
| Runtime on iOS 26 | supported |
| Runtime below iOS 26 | supported down to the 15.0 deployment target, minus the iOS 26-only features (continued processing, external display accessory) |

An app linked against the 26.5 SDK keeps the pre-27 system behaviours on an iOS 27
device. The two behaviours that changed for 27-SDK builds are listed below; both
are already handled in the source behind `__IPHONE_OS_VERSION_MAX_ALLOWED >= 270000`
guards or availability checks, so a future Xcode 27 build picks them up without edits.

## Behaviour changes in iOS 27 and how this app handles them

### Scene-based life cycle is mandatory

Apps built with the iOS 27 SDK must adopt the `UIScene` life cycle or they fail to
launch. LinuxRunner is already scene-based:

* `Info.plist` declares `UIApplicationSceneManifest` with
  `UISceneDelegateClassName = SceneDelegate` and `UIApplicationSupportsMultipleScenes`.
* `SceneDelegate` builds the root controller in
  `scene:willConnectToSession:options:`; `AppDelegate` no longer owns the window on
  iOS 13+ (its `self.window` branch only runs on pre-13 systems).

No migration is required. Re-verify on a 27-SDK build that no code path relies on
`UIApplicationDelegate.window` being non-nil.

### External displays

`windowExternalDisplayNonInteractive` scenes are no longer offered automatically to
apps built with the iOS 27 SDK. The app already registers the accessory explicitly:

* `LRExternalAccessoryOwner` calls
  `-[UIViewController registerSceneAccessory:]` with
  `+[UISceneAccessory externalNonInteractiveSceneAccessoryWithConfiguration:]`
  and a `UIWindowSceneSessionRoleExternalDisplayNonInteractive` configuration,
  guarded by `#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 270000` and `@available(iOS 27.0, *)`.
* Source: `app/LinuxRunner/GUIViewController.m` (search for `LRExternalAccessoryOwner`).

With a 26.5-SDK build the guard compiles out and the legacy
`UIWindowSceneSessionRoleExternalDisplay` session is offered as before, so DeX-style
output keeps working on iOS 27 today. Building with Xcode 27 switches to the
accessory path automatically.

### `canOpenURL:` deprecation

`canOpenURL:` is deprecated in iOS 27 in favour of attempting the open and handling
failure. The single call site (StikDebug / JIT handoff in `ManagerView.requestAttachment()`)
was replaced with `UIApplication.open(_:options:completionHandler:)` only. The
`LSApplicationQueriesSchemes` entry is retained for compatibility but is no longer
required by that code path.

### Privacy manifest

`app/LinuxRunner/PrivacyInfo.xcprivacy` was added and wired into the app target's
Resources phase. It declares no tracking and no collected data, and the four
required-reason API categories the app actually uses: UserDefaults (`CA92.1`),
file timestamps (`C617.1`), disk space (`E174.1`) and system boot time (`35F9.1`).

## Optional entitlements for iOS 26/27 background work

These are provisioning-time capabilities; they cannot be exercised by an unsigned
or self-signed build, so they are documented rather than enabled:

| Capability | Entitlement | Where it applies |
| --- | --- | --- |
| Background GPU Access | `com.apple.developer.background-tasks.continued-processing.gpu` | lets a `BGContinuedProcessingTask` keep rendering through Metal while the app is backgrounded; set `request.requiredResources = .gpu` after checking `BGTaskScheduler.shared.supportedResources.contains(.gpu)` |
| Background tasks — continued processing | `BGTaskSchedulerPermittedIdentifiers` | already present as `$(PRODUCT_BUNDLE_IDENTIFIER).linuxtask.*`; continued-processing identifiers support a trailing wildcard |
| Background Neural Engine (iOS 27) | `com.apple.developer.background-tasks.continued-processing.inference` | only relevant if a background task uses Core AI on the Neural Engine |

Long installs currently keep the app alive through `BGContinuedProcessingTask` plus a
`beginBackgroundTask` assertion (`app/LinuxRunner/LongTaskCenter.swift`). Without the
GPU entitlement the renderer must not be started while the app is backgrounded.

## Building against the iOS 27 SDK

GitHub's `macos-26` runners top out at Xcode 26.6 / SDK 26.5. To produce a 27-SDK
build, run the same workflow on a machine with Xcode 27 installed:

```sh
DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer \
  BUNDLE_ID=dev.linuxrunner.app scripts/build-ipa.sh --unsigned
```

Nothing else changes: the 27-only code paths are already behind compile guards.
