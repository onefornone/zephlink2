"""Run by the build after `flutter create`. It adds the Android permissions,
background services, and notification-listener service used by the app.
"""
import glob
import os
import re
import shutil

MANIFEST = 'android/app/src/main/AndroidManifest.xml'
PERMISSIONS = [
    'INTERNET',
    'ACCESS_NETWORK_STATE',
    'ACCESS_WIFI_STATE',
    'WAKE_LOCK',
    'FOREGROUND_SERVICE',
    'FOREGROUND_SERVICE_CONNECTED_DEVICE',
    'FOREGROUND_SERVICE_MEDIA_PROJECTION',
    'CHANGE_WIFI_STATE',
    'POST_NOTIFICATIONS',
    'REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
    'CAMERA',
    'SYSTEM_ALERT_WINDOW',
    'MANAGE_EXTERNAL_STORAGE',
    'READ_EXTERNAL_STORAGE',
]

# Find the app's code folder and package name that flutter create made.
activities = glob.glob('android/app/src/main/**/MainActivity.*', recursive=True)
if not activities:
    raise SystemExit('Could not find MainActivity. Did flutter create run?')
old = activities[0]
code_dir = os.path.dirname(old)
package = re.search(r'^package\s+([\w.]+)', open(old, encoding='utf-8').read(), re.M).group(1)

# Replace MainActivity and add the service, using the real package name.
for name in (
    'MainActivity.kt',
    'KeepAliveService.kt',
    'NotificationForwardingService.kt',
    'ScreenBridge.kt',
    'QuickActions.kt',
    'ScreenCaptureService.kt',
    'RemoteControlService.kt',
    'ToolsBridge.kt',
):
    text = open(os.path.join('platform/android', name), encoding='utf-8').read()
    text = re.sub(r'^package\s+[\w.]+', 'package ' + package, text, count=1, flags=re.M)
    open(os.path.join(code_dir, name), 'w', encoding='utf-8').write(text)
if old.endswith('.java'):
    os.remove(old)  # an old Java MainActivity would clash with the Kotlin one

# Manifest.
s = open(MANIFEST, encoding='utf-8').read()
missing = [p for p in PERMISSIONS if 'permission.' + p + '"' not in s]
perms = ''.join(
    '    <uses-permission android:name="android.permission.%s"/>\n' % p for p in missing
)
if perms:
    s = s.replace('<application', perms + '    <application', 1)
if 'android.intent.category.LAUNCHER' not in s.split('<application')[0]:
    queries = (
        '    <queries>\n'
        '        <intent>\n'
        '            <action android:name="android.intent.action.MAIN" />\n'
        '            <category android:name="android.intent.category.LAUNCHER" />\n'
        '        </intent>\n'
        '    </queries>\n'
    )
    s = s.replace('<application', queries + '    <application', 1)
service = (
    '        <service android:name="%s.KeepAliveService" android:exported="false"\n'
    '            android:foregroundServiceType="connectedDevice"/>\n' % package
)
if 'KeepAliveService' not in s:
    s = s.replace('</application>', service + '    </application>', 1)
elif 'foregroundServiceType="dataSync"' in s:
    s = s.replace('foregroundServiceType="dataSync"', 'foregroundServiceType="connectedDevice"')
capture_service = (
    '        <service android:name="%s.ScreenCaptureService" android:exported="false"\n'
    '            android:foregroundServiceType="mediaProjection"/>\n' % package
)
if 'ScreenCaptureService' not in s:
    s = s.replace('</application>', capture_service + '    </application>', 1)
control_service = (
    '        <service android:name="%s.RemoteControlService"\n'
    '            android:label="Zephlink remote control"\n'
    '            android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE"\n'
    '            android:exported="true">\n'
    '            <intent-filter>\n'
    '                <action android:name="android.accessibilityservice.AccessibilityService" />\n'
    '            </intent-filter>\n'
    '            <meta-data android:name="android.accessibilityservice"\n'
    '                android:resource="@xml/zephlink_accessibility" />\n'
    '        </service>\n' % package
)
if 'RemoteControlService' not in s:
    s = s.replace('</application>', control_service + '    </application>', 1)
notification_service = (
    '        <service android:name="%s.NotificationForwardingService"\n'
    '            android:label="Zephlink notification forwarding"\n'
    '            android:permission="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE"\n'
    '            android:exported="true">\n'
    '            <intent-filter>\n'
    '                <action android:name="android.service.notification.NotificationListenerService" />\n'
    '            </intent-filter>\n'
    '        </service>\n' % package
)
if 'NotificationForwardingService' not in s:
    s = s.replace('</application>', notification_service + '    </application>', 1)

# Make shared files from Android's system chooser open Zephlink, including
# content:// attachments from Photos and file-manager apps.
activity = re.search(
    r'(<activity\b[^>]*android:name="[^"]*MainActivity"[^>]*>)(.*?)(</activity>)',
    s,
    re.S,
)
if activity is None:
    raise SystemExit('Could not find the generated Android MainActivity manifest entry.')
opening, body, closing = activity.groups()
if 'android:launchMode=' not in opening:
    opening = opening[:-1] + '\n            android:launchMode="singleTask">'
share_filters = '''            <intent-filter>
                <action android:name="android.intent.action.SEND" />
                <category android:name="android.intent.category.DEFAULT" />
                <data android:mimeType="*/*" />
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.SEND_MULTIPLE" />
                <category android:name="android.intent.category.DEFAULT" />
                <data android:mimeType="*/*" />
            </intent-filter>
'''
if 'android.intent.action.SEND_MULTIPLE' not in body:
    body = body + share_filters
s = s[:activity.start()] + opening + body + closing + s[activity.end():]
open(MANIFEST, 'w', encoding='utf-8').write(s)
print('Android project patched for package', package)

# Replace Flutter's default Android launcher icon and provide a monochrome
# notification icon for Android's notification drawer.
res_dir = 'android/app/src/main/res'
for density in ('mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi'):
    mipmap = os.path.join(res_dir, 'mipmap-' + density)
    os.makedirs(mipmap, exist_ok=True)
    shutil.copyfile(
        os.path.join('assets', 'android-icons', density + '.png'),
        os.path.join(mipmap, 'ic_launcher.png'),
    )
drawable = os.path.join(res_dir, 'drawable')
os.makedirs(drawable, exist_ok=True)
for source, target in (
    ('zephlink_launcher_foreground.xml', 'zephlink_launcher_foreground.xml'),
    ('zephlink_launcher_background.xml', 'zephlink_launcher_background.xml'),
    ('zephlink_notification_icon.xml', 'ic_zephlink_notification.xml'),
):
    shutil.copyfile(
        os.path.join('platform', 'android', source),
        os.path.join(drawable, target),
    )
xml_dir = os.path.join(res_dir, 'xml')
os.makedirs(xml_dir, exist_ok=True)
shutil.copyfile(
    os.path.join('platform', 'android', 'zephlink_accessibility.xml'),
    os.path.join(xml_dir, 'zephlink_accessibility.xml'),
)
values_dir = os.path.join(res_dir, 'values')
os.makedirs(values_dir, exist_ok=True)
shutil.copyfile(
    os.path.join('platform', 'android', 'zephlink_strings.xml'),
    os.path.join(values_dir, 'zephlink_strings.xml'),
)
adaptive = os.path.join(res_dir, 'mipmap-anydpi-v26')
os.makedirs(adaptive, exist_ok=True)
shutil.copyfile(
    os.path.join('platform', 'android', 'zephlink_launcher_adaptive.xml'),
    os.path.join(adaptive, 'ic_launcher.xml'),
)

# Configure a stable signing key when key.properties is supplied by the
# workflow. Local builds without it keep Flutter's debug-signing fallback.
gradle_files = [
    path for path in (
        'android/app/build.gradle.kts',
        'android/app/build.gradle',
    ) if os.path.exists(path)
]
if not gradle_files:
    raise SystemExit('Could not find the Android app Gradle build file.')
gradle_path = gradle_files[0]
gradle = open(gradle_path, encoding='utf-8').read()
if gradle_path.endswith('.kts'):
    compile_options = (
        '    compileOptions {\n'
        '        sourceCompatibility = JavaVersion.VERSION_17\n'
        '        targetCompatibility = JavaVersion.VERSION_17\n'
        '    }'
    )
    desugared_compile_options = (
        '    compileOptions {\n'
        '        isCoreLibraryDesugaringEnabled = true\n'
        '        sourceCompatibility = JavaVersion.VERSION_17\n'
        '        targetCompatibility = JavaVersion.VERSION_17\n'
        '    }'
    )
    if 'isCoreLibraryDesugaringEnabled' not in gradle:
        if compile_options not in gradle:
            raise SystemExit('Could not find Android compileOptions in the app Gradle file.')
        gradle = gradle.replace(compile_options, desugared_compile_options, 1)
    desugaring_dependency = (
        'dependencies {\n'
        '    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n'
        '}'
    )
    if 'coreLibraryDesugaring(' not in gradle:
        gradle = gradle.rstrip() + '\n\n' + desugaring_dependency + '\n'
    with open(gradle_path, 'w', encoding='utf-8') as f:
        f.write(gradle)
    print('Android core library desugaring enabled.')
if 'key.properties' not in gradle:
    if gradle_path.endswith('.kts'):
        gradle = (
            'import java.io.FileInputStream\n'
            'import java.util.Properties\n\n' + gradle
        )
        plugin_end = '}\n\nandroid {'
        if plugin_end not in gradle:
            raise SystemExit('Could not find the Android Gradle plugin block.')
        gradle = gradle.replace(
            plugin_end,
            '}\n\n'
            'val keystoreProperties = Properties()\n'
            'val keystorePropertiesFile = rootProject.file("key.properties")\n'
            'if (keystorePropertiesFile.exists()) {\n'
            '    keystoreProperties.load(FileInputStream(keystorePropertiesFile))\n'
            '}\n\n'
            'android {',
            1,
        )
        build_types = '    buildTypes {'
        if build_types not in gradle:
            raise SystemExit('Could not find the Android release build type.')
        gradle = gradle.replace(
            build_types,
            '    if (keystorePropertiesFile.exists()) {\n'
            '        signingConfigs {\n'
            '            create("release") {\n'
            '                keyAlias = keystoreProperties["keyAlias"] as String\n'
            '                keyPassword = keystoreProperties["keyPassword"] as String\n'
            '                storeFile = file(keystoreProperties["storeFile"] as String)\n'
            '                storePassword = keystoreProperties["storePassword"] as String\n'
            '            }\n'
            '        }\n'
            '    }\n\n'
            '    buildTypes {',
            1,
        )
        debug_signing = '            signingConfig = signingConfigs.getByName("debug")'
        if debug_signing not in gradle:
            raise SystemExit('Could not find the default Android release signing.')
        gradle = gradle.replace(
            debug_signing,
            '            signingConfig = if (keystorePropertiesFile.exists()) {\n'
            '                signingConfigs.getByName("release")\n'
            '            } else {\n'
            '                signingConfigs.getByName("debug")\n'
            '            }',
            1,
        )
    else:
        raise SystemExit(
            'Groovy Gradle files are not supported for persistent Android signing.'
        )
    with open(gradle_path, 'w', encoding='utf-8') as f:
        f.write(gradle)
    print('Android release signing supports key.properties')

# ---------------------------------------------------------------------------
# Fix: "Update this project to use a newer compileSdk of at least 34".
# Some plugins (open_filex, file_selector_android ...) are built against an
# older Android SDK than the AndroidX libraries they use need. A project-local
# Gradle script raises compileSdk to 35 for every module below it.
# It only raises, never lowers.
# ---------------------------------------------------------------------------
INIT = r'''allprojects {
    afterEvaluate { p ->
        def ext = p.extensions.findByName("android")
        if (ext == null) return
        def current = 0
        try {
            def raw = ext.compileSdkVersion
            def m = (raw =~ /(\d+)/)
            if (m.find()) current = m.group(1).toInteger()
        } catch (Throwable ignored) { }
        if (current < 35) {
            ext.compileSdkVersion(35)
            println "zephlink: compileSdk " + current + " -> 35 for " + p.name
        }
    }
}
'''
gradle_init = 'android/zephlink-compilesdk.gradle'
with open(gradle_init, 'w', encoding='utf-8') as f:
    f.write(INIT)
root_gradle = 'android/build.gradle.kts'
with open(root_gradle, encoding='utf-8') as f:
    root_build = f.read()
apply_line = 'apply(from = "zephlink-compilesdk.gradle")'
root_build = root_build.replace(apply_line, '').lstrip()
with open(root_gradle, 'w', encoding='utf-8') as f:
    f.write(apply_line + '\n\n' + root_build + '\n')
print('Project-scoped Android compileSdk override written.')
