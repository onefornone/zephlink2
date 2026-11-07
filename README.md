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
- A file that failed to send (or was refused) shows a **Send again** button, on Home and in Files, plus **Send failed again** to retry them all. The original file must still be where it was.
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
- **Smooth video (H.264, experimental)**: when an Android phone shares to a Windows PC, the phone can send real hardware-encoded video instead of pictures. It uses much less Wi-Fi. It is only used when the PC can play it. The Windows build tries to include a video player (media_kit); if that cannot be built, the app is built without it and simple video is used. If the video does not start within a few seconds, Zephlink switches back to simple video by itself, and the viewer has a "Switch to simple video" button. PC to phone sharing always uses simple video.
- **Quick actions** (Remote tab, after control is allowed): the phone can lock, put to sleep, turn the screen off, shut down, restart or sign out of the PC, and open File Explorer, Downloads, Calculator, Notepad, Task Manager, Settings or a website. The PC can do lock screen, power menu, screenshot, quick settings, notifications, home, back, recent apps, files, settings, camera, flashlight, volume, open any installed app, or open a website on the phone. Shut down, restart and sign out ask the PC's owner again each time. Android cannot be switched off or restarted by an app, so "Power menu" opens Android's own menu on the phone. Some Android versions refuse to open apps while the phone is locked or Zephlink is closed.
- **Viewer controls**: the picture is fitted to the window (no scrolling), with a full screen button, a rotate button (landscape and portrait), zoom, screenshot, and a quick actions sheet. On Android, full screen hides the system bars.
- **View anytime**: in the share controls, *Let (device) view this screen anytime* skips the question after you connect, and *Open their screen automatically* starts viewing as soon as the link is up. Android still shows its own "Start now" screen-capture box each time sharing starts; Android does not allow an app to skip it.
- **Open files and apps from the PC**: Zephlink looks for any file manager on the phone (Files by Google, ZArchiver, Samsung, Xiaomi, and others). If Android blocks it while Zephlink is in the background, turn on **Display over other apps** with the button in the share controls.
- **Touchpad**: the touchpad takes your finger for itself, so the page no longer scrolls or moves mid-drag. Drag to move, tap to click, hold for right click, two fingers to scroll (or use the strip on the right).
- **Find my phone** (Remote tab on the PC): *Ring my phone* makes the phone play a loud alarm sound even on silent, and shows the phone's battery level. It stops after about a minute and a half, or when you tap Stop on either device. The phone can turn this off in Settings, *Let my PC ring this phone*. The phone must have Zephlink running (the *Keep running after closing* setting helps). Do Not Disturb modes that block alarms can still keep it quiet.
- **Browse files** (Files tab, *Browse files on ...*): look through the other device's drives and folders, and tap a file to have it sent to you like any other transfer. The owner of that device is asked once per link (or never, if they turn on *Let linked devices browse my files* in Settings). It is read-only: nothing can be changed or deleted. On the phone, Android also needs *Allow access to all files* for Zephlink; Zephlink opens that screen for you the first time.
- **QR pairing**: on the PC, Home has *Show QR code* (a big "Scan with your phone" window that renews its code by itself). On the phone, Home has *Scan QR code*. Both devices still ask you to approve the first pairing.
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
