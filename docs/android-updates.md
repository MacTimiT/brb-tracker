# Android updates and signing

Download the signed APK from [GitHub Releases](https://github.com/MacTimiT/brb-tracker/releases/latest). You can install it over v0.4.1 or later if the installed APK uses the BRB Tracker release certificate. Android keeps local reports and the saved GitHub token when updating in place.

The certificate SHA-256 fingerprint is `42b2efa378ed4600ef1938221378da382d5abcdb7d787eef2fdea726705481bb`. Releases use package ID `dev.mactimit.brb_tracker` and an increasing version code. Development APKs use a separate debug key. Build production APKs with `flutter build apk --release` and sign with the existing release key before uploading.

## Upgrade from v0.4.0 or earlier

The older previews used temporary signing keys. Moving from one of those previews to the signed release requires one reinstall. Uninstalling removes local reports and the saved token. Publish the reviewed reports you need before uninstalling, or migrate their local JSON through the signed v0.4.2 debug build.

With Android platform tools and USB debugging, run this from Windows Command Prompt or a shell with binary-safe redirection before uninstalling the old debug app:

```sh
adb exec-out run-as dev.mactimit.brb_tracker tar -C no_backup -cf - brb-jobs > brb-reports.tar
```

Confirm the archive contains your jobs and keep it private. After uninstalling, install [signed v0.4.2](https://github.com/MacTimiT/brb-tracker/releases/tag/v0.4.2), open it once, and restore the archive:

```sh
adb shell -T run-as dev.mactimit.brb_tracker tar -C no_backup -xf - < brb-reports.tar
```

Reopen the app, confirm the reports appear, then install the latest signed release over it. Enter your GitHub token again in the app.
