# Zephlink

Your phone and your PC, one breeze apart. Files, clipboard, notifications, screen mirroring and remote control between Android and Windows. No account, no cloud.

**Status:** Pairing, discovery, encrypted file and folder transfers with SHA-256 integrity checks and resume after a connection drop, Android Share-to-Zephlink and received-file access, Windows Explorer sharing, QR pairing, transfer notifications, optional Android-to-Windows phone-notification forwarding, clipboard sharing, and GitHub Release update notices are implemented. Screen mirroring and remote control are included but **experimental**: they were written without being run on real devices, so expect rough edges and report what you see.

## Get the apps (no coding tools needed)

1. Make a free account at github.com, then create a new **empty repository** (name it `zephlink`).
2. Upload **everything in this folder** to it (the **Add file > Upload files** button works; drag the whole folder contents in, including the hidden `.github` folder).
3. Open the **Actions** tab. A run called **Build Zephlink** starts by itself. If it does not, choose it on the left and press **Run workflow**.
4. When it shows a green tick, open the run and scroll to **Artifacts**:
   - `zephlink-android-apk`: unzip it and install `app-release.apk` on your phone.
   - `zephlink-windows`: unzip it, then run `Zephlink-Setup.exe` (or open the zip and run `zephlink.exe`).
5. Windows may warn "unknown publisher". Choose **More info**, then **Run anyway**. Android may ask you to allow installing from your browser or files app.

If a run turns red, open it, copy the red error text and paste it to your AI coding tool or to Claude, and it will tell you the fix.

### Installing Android updates without uninstalling

Android installs a new APK over the old app only when the package ID and the
**signing key** match and the version number is higher. The workflow raises
the version number by itself. For the key, add four **Actions secrets** to
your GitHub repository (Settings, Secrets and variables, Actions, New
repository secret):

- `ANDROID_KEYSTORE_BASE64`: the whole text of the key file, as one line
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

Keep a backup of the key file (`zephlink-release.jks`) somewhere safe, and
never upload it or the passwords to the repository. If it is lost, phones
must uninstall the app once before they can install a build with a new key.

Without the four secrets every build uses a temporary key, and Android will
refuse to update over a build signed with a different key. Phones that already
have an older, temporarily signed build must uninstall it **once**; after that,
updates install over the top and keep your data. In the build log, the step
**Show the APK signing fingerprint** prints the key's SHA-256: it must be the
same on every build.

To make a new key yourself:

```
keytool -genkeypair -v -keystore zephlink-release.jks -storetype PKCS12 -keyalg RSA -keysize 2048 -validity 10000 -alias zephlink
```

On Windows PowerShell, make the one-line text with
`[Convert]::ToBase64String([IO.File]::ReadAllBytes("zephlink-release.jks"))`.

## Link your phone and PC (one time)

1. Install and open Zephlink on **both** devices, on the **same Wi-Fi** (a phone hotspot works too).
2. On the PC, Windows asks to allow network access. Choose **Private networks** and **Allow**.
3. Open **Devices** on both (the gear icon, then Devices, or the button on the Home card). Each device shows **Your address on this Wi-Fi**, for example `192.168.1.23`.
4. On one device, tap **Connect** next to the other under *Found on this Wi-Fi*. Compare the six-digit verification code shown on both devices, then approve the first pairing on both.
5. If discovery is blocked, choose **Show my code** on one device and **Enter a code** on the other, then enter its address and code. Approve on both devices.
6. Done. The paired identity is pinned. Later connections to that trusted device are verified automatically and do not require another approval.

## Send files and text

- **Files tab**: choose files or a folder (or drag files into the window on Windows). Folder contents are sent as individual files, preserving their relative directory structure without building a large archive in memory. Android copies selected files and folders to a temporary cache using bounded streams; Windows scans the chosen folder recursively. On Android, you can also use **Share** in Photos or a file manager and choose Zephlink. On Windows, right-click a file and choose **Send with Zephlink**, or drag it into the window. Shared files wait until a device is connected. Progress and cancel controls are shown for active transfers.
- If Wi-Fi or the link drops mid-transfer, the receiver keeps a partial file and the transfer can be resumed from its acknowledged byte offset after reconnecting. The transfer queue is currently in memory, so a sender app restart does not preserve the resume button.
- Received files go to your Downloads folder under `Zephlink` on Windows and, on Android 10+, to the shared `Downloads/Zephlink` folder. Use **Open in file manager** on Android to open the folder chooser. Older Android versions keep files in app-specific storage. Recent sent and received files, image previews, and a view button are also on Home.
- Android and Windows show a system notification when a file is received. Notifications can be disabled in Settings.
- **Phone notification forwarding (optional)**: on Android, turn on **Forward phone notifications to Windows** in Settings and grant Android's notification-listener access. While connected to Windows, Zephlink forwards notification text over the encrypted link. The Windows Inbox supports copying a detected 4–8 digit code, replying when the original notification offers a text-reply action, and dismissing the original notification. Disable the toggle or revoke Android access at any time to stop forwarding.
- **Clipboard tab**: send your clipboard or typed text, and turn on **Share clipboard automatically** if you want copy on one device to appear on the other.

### App versions and update notices

Devices running different Zephlink app releases can connect when they share the
same link protocol. The app checks the public GitHub Releases page about once
per day and offers a link when a newer stable release is published. A release
must be published for the update notice to appear.

## Screen mirroring and remote control (experimental)

Open the **Screen** tab on either device.

- **See the other device's screen**: tap *Ask to see their screen*. The other device is asked first (on Android, Android's own screen-capture box also appears). The picture is sent as small JPEG images over the same encrypted link. Choose Smooth, Balanced or Sharp before sharing.
- **Share this screen**: choose a quality and tap *Start sharing*. The other device must still accept before it sees anything. Sharing stops when you tap Stop, when either side stops, or when the link drops.
- **Control**: a separate permission, off by default, asked every time. It ends when the link ends. The PC can click and drag on the phone picture to tap, swipe and type on the phone, and the phone can control the PC. Keys the PC accepts are limited (letters, numbers, arrows, media and common editing keys).
- **Android control needs one manual step**: in Android Settings, Accessibility, turn on **Zephlink remote control**. Zephlink does not read your screen with it; it only performs the taps and swipes you allowed. Android may warn that accessibility services are powerful; that is expected.
- **Remote tab (phone to PC)**: a touchpad, keyboard, media keys and slide clicker for the PC, after the PC owner allows it.
- Not supported yet: sound, clipboard inside the mirror, controlling a PC password screen or the Windows security prompt (Windows blocks that).

## Keeping it running

- **Android**: Settings, **Keep running after closing** shows a small notification so Android keeps the link alive with the screen off. It uses the *connected device* service type, which does not have the 6-hour daily limit of the older *data sync* type. Tap **Allow unrestricted battery use** if your phone stops it.
- **Windows**: Settings, **Keep running after closing** controls whether closing the window hides Zephlink in the system tray or exits. Right-click the tray icon for **Open** and **Quit**. The installer adds **Send with Zephlink** to File Explorer. Settings or the installer can also enable **Start with Windows**, which starts Zephlink hidden in the tray (the window may flash for a moment). Only one copy runs at a time: starting it again, or using **Send with Zephlink**, hands the files to the running copy. The installer can optionally open the Windows firewall for Zephlink (it asks for administrator rights in that case; choose the all-users option at the start of the installer).

## Dark mode

Open **Settings** (gear icon) and pick **System**, **Light** or **Dark**. Your choice is remembered.

## For developers

```
flutter pub get
flutter run -d windows      # or -d <your android device>
flutter test
```

The `android/` and `windows/` folders are generated by `flutter create` (the build workflow does it for you). Layout:

- `lib/theme/` colors for light and dark, fonts, theme switch
- `lib/widgets/` shared building blocks
- `lib/screens/` one file per tab
- `lib/shell/` adaptive layout (bottom bar on phone, top tabs on PC)
- `lib/link/` pairing, encryption (in a background worker so big files do not freeze the app), discovery
- `lib/features/` file transfer and screen mirroring/control
- `lib/platform/` Android and Windows specifics (tray, single instance, Windows mouse/screen access)
