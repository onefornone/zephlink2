# Zephlink build plan

Zephlink links your Android phone and your Windows PC: files, clipboard, notifications, screen mirroring and remote control. No account, no cloud, no monthly cost.

This is a **separate project**. It is inspired by NectarLink but is not a copy or a fork.

---

## 1. What we are building

| Area | What the user gets |
|---|---|
| Quick connect | Open the app and your devices find each other on their own (about a second). No typing IP addresses. |
| Always on | Runs in the background all day: a notification-bar service on Android, a tray icon on Windows. Starts with the device. |
| Files | Send files and folders both ways. Drag and drop on the PC, share sheet on the phone. Resumes if the Wi-Fi drops. |
| Screen | Phone screen on the PC, and PC screen on the phone, with mouse, keyboard and touch control. |
| Clipboard | Copy on one device, paste on the other. Shared clipboard board with pinned items. |
| Notifications and messages | Phone notifications appear on the PC with Reply and Copy code buttons. |
| Remote | Phone as touchpad, keyboard, media remote and slide remote for the PC. |
| New features | Scheduled send, auto-sort received files, Ping me when done, Focus mode, Guest QR share, search across both devices. |
| Look | Material 3, tabs, light and dark mode (done in this first drop). |

Tabs: Android has Connect, Files, Screen, Remote, More. Windows has Home, Files, Screen, Inbox, Remote, Tools. The app switches layout by window width, so one codebase does both.

## 2. Technology choices (and why)

| Part | Choice | Why |
|---|---|---|
| App UI, both platforms | **Flutter (Dart)** | One codebase for Android and Windows, great Material 3 support, easiest for AI coding tools to work with. |
| Android-only features | **Kotlin** small modules called from Flutter (platform channels) | Notification access, screen capture and background services must be native. |
| Windows-only features | Flutter plugins plus FFI to Windows APIs | Tray icon, start with Windows, mouse and keyboard injection. |
| Device-to-device link | Local network, **WebSocket** with our own end-to-end encryption | Free, no server, works offline. |
| Discovery | **mDNS** (`_zephlink._tcp`) plus last-known address | Finds the other device in about a second on the same Wi-Fi. |
| Encryption | X25519 key exchange and ChaCha20-Poly1305 (Dart `cryptography` package) | Modern, well-reviewed, no custom crypto. |
| Local storage | `shared_preferences` for settings, `flutter_secure_storage` for keys | Keys live in Android Keystore and Windows DPAPI. |
| Config files | `pubspec.yaml` (Flutter's version of NectarLink's `Cargo.toml`) | Flutter's standard. |
| Build and release | **GitHub Actions** (free) | Builds the APK and the Windows installer for you. You never install Flutter or Visual Studio. |

NectarLink uses Rust, Qt and Kotlin. Those are excellent but very hard to build without coding experience. Flutter gives the same result with far less setup.

## 3. How it fits together

```
 Phone (Android)                                   PC (Windows)
 ┌─────────────────────────┐                      ┌─────────────────────────┐
 │ Flutter UI (tabs)       │                      │ Flutter UI (tabs)       │
 ├─────────────────────────┤                      ├─────────────────────────┤
 │ Feature modules         │                      │ Feature modules         │
 │ files · clipboard ·     │                      │ files · clipboard ·     │
 │ notifications · mirror  │                      │ mirror view · remote    │
 ├─────────────────────────┤   encrypted          ├─────────────────────────┤
 │ Link layer              │◄───────────────────► │ Link layer              │
 │ discovery · pairing ·   │   WebSocket on LAN   │ discovery · pairing ·   │
 │ secure channel          │                      │ secure channel          │
 ├─────────────────────────┤                      ├─────────────────────────┤
 │ Android service (Kotlin)│                      │ Tray + autostart        │
 │ keeps it alive 24/7     │                      │ keeps it alive 24/7    │
 └─────────────────────────┘                      └─────────────────────────┘
```

Rule: the **link layer** knows nothing about the screen, and the **UI** knows nothing about sockets. That keeps each piece easy to change.

Folder layout (already created):

```
lib/
  main.dart, app.dart, app_scope.dart
  theme/        colors (light and dark), fonts, theme switch
  data/         sample data used until the real link layer exists
  widgets/      shared building blocks (cards, tiles, toggles, logo)
  shell/        adaptive layout: bottom bar on phone, top tabs on PC
  screens/      Connect, Files, Screen, Remote, Inbox, Tools, More, Settings
  link/         (Phase 1) discovery, pairing, secure channel
  features/     (Phase 2+) files, clipboard, notifications, mirror, remote
```

## 4. Security

1. **Pairing** with a one-time 6-digit code (QR scanning later). It expires in 5 minutes and locks after 3 wrong tries.
2. After pairing, each device **pins the other's public key**. Anyone else is refused.
3. Every message is **end-to-end encrypted**. Even someone on your Wi-Fi sees only noise.
4. Risky features (remote control, PC file browsing, running commands) are **off until you turn them on**, per device.
5. **No account, no cloud, no tracking.** The only internet use is the optional update check against GitHub.

## 5. Phases

Each phase ends with an app you can install and use.

### Phase 0: Foundation (done in this drop)
- Flutter project, Material 3 theme, **light and dark mode** with a System/Light/Dark switch (saved between launches).
- Adaptive tabs: bottom bar on phone, top tabs on PC.
- All screens built with sample data so you can see and judge the design.
- GitHub Actions that build the APK and the Windows app.

### Phase 1: Real connection (done in this drop)
- **Pairing with a 6-digit code** (shown on one device, typed on the other). The code works once, expires in 5 minutes and is locked after 3 wrong tries.
- **Discovery** by a small "I'm here" broadcast on the Wi-Fi every 2 seconds (built into Dart, no extra package, works on Android and Windows). If a router blocks it, pair by typing the other device's IP address. (Plan change: this replaces mDNS, which needs a native plugin on each system.)
- **Pinned keys**: each device has an Ed25519 identity key. After pairing, each stores the other's public key and refuses anyone else.
- **Encrypted link**: a fresh X25519 key exchange for every connection, then ChaCha20-Poly1305 on every message, numbered so nothing can be replayed or reordered.
- **Remembered identities**: paired public keys are pinned locally; first pairing requires matching verification and approval on both devices, while trusted reconnects are verified automatically.
- **Real status**: Connected, Connecting, Searching or Not paired, plus live round-trip time (ping every 5 seconds).
- **Settings that apply**: device name, Quick connect, file receiving, notifications, clipboard and background behavior.

### Phase 2: Files, clipboard and always-on (in progress)
Done in this drop:
- **Discovery fix**: besides the "I'm here" broadcast, each device now scans its own Wi-Fi network (like a router would) so it still finds the other when broadcasts are blocked. Each device shows its **address** so you can also type it.
- **Pairing with approval on both devices**: connect directly to a discovered device after comparing a short verification code, or use *Show my code* / *Enter a code* when discovery is blocked.
- **QR pairing**: show a short-lived QR code or scan it on Android; matching verification and approval on both devices are still required.
- **Files**: send many files with progress, speed, cancel, and drag and drop on Windows. Encrypted in large chunks, with disk-backed flow control and background crypto for large transfers.
- **Folder transfers**: choose a folder on Android or Windows; files are sent individually with their relative paths preserved, without building a large archive in memory.
- **Resume on reconnect**: paused transfers can resume from the receiver's flushed partial-file offset and are verified against the full-file SHA-256 checksum. The transfer queue itself is not yet persisted across sender app restarts.
- **Share into the app**: Android Share sheet from Photos and file managers; Windows File Explorer's *Send with Zephlink* context action.
- **Received-file notifications**: local notifications on Android and Windows, with a Settings toggle.
- **Received folder access**: Windows opens the Downloads folder; Android browses received files inside Zephlink's app storage.
- **Clipboard and text**: send your clipboard or typed text, optional automatic sharing, and a list of what you received.
- **Recent files on Home**: sent and received transfers, image thumbnails, and a view button replace the activity feed.
- **Always-on**: Android foreground service with a Wi-Fi lock and battery-optimisation prompt; Windows closes to the system tray and can start with Windows.

Still to do: Android start-on-boot and persisting the transfer queue across app restarts.

### Phase 3: Phone notifications, remote, media
- **Phone notification forwarding**: Android-to-Windows forwarding with explicit notification-listener permission, encrypted transport, Inbox, copy-code, supported reply, and dismiss actions.
- Touchpad, keyboard, slide remote, media keys from the phone.
- Find my phone, phone controls from PC.

### Phase 4: Screen mirroring
- **Status: Step A and control are built (experimental, untested on real devices).** Step B (H.264) is not.
- Step A (simple, works everywhere): screen frames as JPEG over the encrypted link, about 20 to 30 fps.
- Step B (smooth): H.264 hardware encoding on the phone, hardware decoding on the PC, 60 fps.
- Control: mouse and keyboard on the PC, touch on the phone. PC-to-phone viewing.
- Phone apps in their own PC windows (needs a virtual display; later).

### Phase 5: The new features
- Scheduled send, auto-sort, Ping me when done, Focus mode, Guest QR share, search.

### Phase 6: Polish and release
- Accessibility, translations, automatic update from GitHub Releases.
- Stable Android release signing for in-place updates (requires a backed-up keystore); optionally a code-signing certificate for Windows.

## 6. Free build and release

1. Put the project in a GitHub repository (free).
2. Every time you upload a change, GitHub Actions builds the app:
   - **Android:** `app-release.apk` (install on your phone).
   - **Windows:** `Zephlink-Setup.exe` installer and a `.zip` of the app.
3. Download them from the **Actions** tab, under the latest run, in **Artifacts**.
4. To publish a version, create a tag like `v0.1.0`; the same workflow can attach files to a Release (added in Phase 6).

## 7. Honest limits

- **Windows will warn** ("SmartScreen") the first time you run the installer, because it is not code-signed. Choose More info, then Run anyway. A certificate costs money, so we skip it for now.
- **Android may warn** (Play Protect) for sideloaded apps. Tap Install anyway, or turn off scanning briefly.
- **Screen mirroring and notifications** need special Android permissions that you grant once. Android 14 and newer asks for screen-capture consent every session for normal apps.
- **Phone makers' battery savers** (Xiaomi, OnePlus, Samsung and others) can stop background apps. The app will guide you to the right setting.
- Everything involving real phones and networks has to be **tested on your own devices**. No one can fully test it for you.
- Android in-place updates require the same persistent release keystore in the GitHub Actions secrets on every build. The workflow supports this, but the repository owner must configure the four signing secrets; builds without them use a temporary key and cannot update a prior APK.

## 8. How you and your AI tools work on it

1. Change a file (or ask your AI tool to).
2. Upload to GitHub.
3. Wait about 8 minutes for Actions to finish.
4. Download, install, try it.
5. If something is wrong, copy the red error text from the Actions log, or describe what you saw, and ask for a fix.

Ask your tool for **one phase at a time**, and say "do not change anything outside lib/". Always keep `PLAN.md` open so it knows the overall design.
