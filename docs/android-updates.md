# Android preview updates and signing

An isolated detector test APK uses package `dev.mactimit.brb_tracker.test` and launcher name **BRB Tracker Test**. It installs alongside the existing app and keeps its own reports. This lets a phone test detection changes while persistent signing is being configured. It does not migrate existing reports or promise updates between test builds. Build it with `ORG_GRADLE_PROJECT_brbIsolatedPreview=true flutter build apk --debug`.

Android installs an update only when its package ID and signing certificate match the installed app and its version code increases. The v0.2.1, v0.2.2, v0.3.0 and v0.4.0 preview APKs share `dev.mactimit.brb_tracker` and have increasing version codes, but each CI run generated a different debug signing key. Their certificates cannot be made compatible without the missing older private keys. Android will require one uninstall to move from any of those previews to the first stable-signed build.

Uninstalling removes local reports and the saved GitHub token. If you have reports you need, publish reviewed reports from the old app first, or back up `no_backup/brb-jobs` with `adb run-as` while the old debug app is installed. Restore those JSON files after installing and opening the first stable-signed debug preview. The token must be entered again. Keep any backup private because report evidence can contain transcript excerpts.

## Configure a persistent signing key

The owner creates a PKCS12 keystore with alias `brb-tracker`, using the same strong password for the keystore and key. Keep the `.p12` file and password in separate, durable backups. Never commit the key or put it in a chat.

With a JDK installed on Windows, run this in PowerShell from a private directory:

```powershell
keytool -genkeypair -keystore brb-release.p12 -storetype PKCS12 -alias brb-tracker -keyalg RSA -keysize 3072 -validity 10000
```

At **GitHub → repository Settings → Secrets and variables → Actions**, add these repository secrets:

| Secret | Value |
| --- | --- |
| `BRB_ANDROID_KEYSTORE_BASE64` | Base64 encoding of the `.p12` file |
| `BRB_ANDROID_KEYSTORE_PASSWORD` | The keystore/key password |

To copy the base64 value without showing it in the terminal, run this PowerShell command from the directory containing the keystore, then paste into the GitHub secret field:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path .\brb-release.p12))) | Set-Clipboard
```

The [signed preview workflow](../.github/workflows/release-android-preview.yml) checks a successful Android CI run, builds from that exact source commit, signs with those secrets and publishes the APK plus its SHA-256 checksum and public certificate fingerprint. It fails if either secret is missing. Future signed previews must reuse the same key and increase the version code. The CI debug APK is for testing and uses its own temporary key.

## Move local reports with a Windows computer

Install Android platform tools and enable USB debugging, then connect the phone. Use **Command Prompt** for the binary redirection below. Back up before uninstalling:

```bat
adb devices
adb exec-out run-as dev.mactimit.brb_tracker tar -C no_backup -cf - brb-jobs > brb-reports.tar
```

Check that `brb-reports.tar` is nonempty and keep it private. After installing the first stable-signed **debug** preview, open the app once, close it, and restore:

```bat
adb shell -T run-as dev.mactimit.brb_tracker tar -C no_backup -xf - < brb-reports.tar
```

Reopen the app and confirm the reports appear. `run-as` works only for debuggable APKs, so this migration is provided for the first stable-signed debug preview. Published report JSON on the dashboard is unaffected by uninstalling the app.
