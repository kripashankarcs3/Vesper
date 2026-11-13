<p align="center">
  <img src="assets/branding/icon_1024.png" alt="Vesper logo" width="128" height="128">
</p>

<h1 align="center">Vesper</h1>

<p align="center">
  <b>An offline, private companion for WhatsApp on Android.</b><br>
  Recover deleted messages, back up media and save statuses into an encrypted vault on your phone.
</p>

---

## What it does

Vesper runs next to the official WhatsApp app. It never logs in to WhatsApp and never talks to any server. It works only with what Android already gives it: the notifications WhatsApp shows, and the media files WhatsApp saves on the device.

| Feature | How it works |
|---|---|
| **Deleted message recovery** | Messages are recorded from WhatsApp notifications as they arrive. When WhatsApp later shows *"This message was deleted"*, Vesper marks the last message from that sender as deleted, so you can still read it. |
| **Ghost Feed** | A running feed of every captured message, with deleted ones highlighted in red. |
| **Ghost Reply** | Reply to a chat straight from Vesper, using the notification's reply action, without opening WhatsApp. |
| **Media backup** | Images and videos that WhatsApp saves are copied into Vesper's private storage. If the sender deletes them from the chat, Vesper keeps its copy and marks it *Deleted by sender*. |
| **Status Saver** | View the statuses WhatsApp has downloaded, save them to the vault (one by one or all at once), and export a saved one to your gallery (`Pictures/Vesper`). |
| **Encrypted vault** | All records are stored in an AES-256 encrypted database (SQLCipher). The key is kept in Android's hardware-backed secure storage. |
| **App lock** | Opens only after fingerprint, face or device PIN, and locks again as soon as you leave the app. Screenshots and the recent-apps preview are blocked. |

Both **WhatsApp** and **WhatsApp Business** are supported.

## Privacy

- **Offline by design.** The release build does not request the `INTERNET` permission, so it cannot send data anywhere.
- **Stays on the device.** Everything is kept in the app's private storage. Cloud backup and device-to-device transfer are disabled for the app's data.
- **You control it.** *Wipe Local Vault* deletes all recovered messages, backed-up media and saved statuses from the phone.

## Limitations

- Vesper only sees what WhatsApp shows in its **notifications**. Messages from muted chats, chats you are reading at that moment, or chats with notifications turned off are not captured. It cannot read your past chat history.
- Long messages may appear shortened, because notifications shorten them.
- Media is backed up only if WhatsApp has **downloaded** it. Turn on auto-download in WhatsApp for best results.
- Statuses appear only after WhatsApp has downloaded them. Open the **Updates** tab in WhatsApp, then pull to refresh in Vesper.
- Backed-up media files are kept in app-private storage, but unlike the message database they are **not encrypted**.
- Android only.

## Permissions

| Permission | Why |
|---|---|
| Notification access | To read incoming WhatsApp messages and to detect deletions. |
| All files access | To back up WhatsApp media and to read statuses (`Android/media/com.whatsapp/...`). |
| Biometric | To lock and unlock the vault. |

When the app opens, tap **Enable** in the yellow banner to grant notification access and all files access.

## Build and run

Requirements: Flutter (stable channel) and an Android device or emulator with Android 7.0 or newer (minSdk 24).

```bash
flutter pub get
flutter run                  # debug build on a connected device
flutter build apk --release  # build/app/outputs/flutter-apk/app-release.apk
flutter test                 # unit tests
```

> The release build is currently signed with the debug key. Before publishing anywhere, set up a proper release signing key.

## Project structure

```
lib/
  main.dart            App entry, biometric lock, home screen with tabs
  db_helper.dart       Encrypted SQLCipher database (messages, media, statuses)
  vault_key.dart       Safe creation and loading of the vault key
  media_watcher.dart   Watches WhatsApp media folders and backs up files
  status_saver.dart    Finds statuses, saves them to the vault, exports them
  status_screen.dart   Status tab UI and full-screen viewer
test/                  Unit tests for vault key handling and status filtering
tool/generate_icon.py  Generates the logo and icon images
assets/branding/       Logo and icon source images
```

## Logo

The logo shows an evening star (*vesper*) inside a shield, with a **V** at the bottom: a star that keeps watch over your vault. To regenerate the images and launcher icons:

```bash
python tool/generate_icon.py
dart run flutter_launcher_icons
```

## Disclaimer

Vesper is an independent personal project. It is not affiliated with, endorsed by or connected to WhatsApp or Meta. Use it only on your own device and respect the privacy of the people you chat with.
