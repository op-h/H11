# H11

A small notebook that lives on your phone and your computer at once. Write an idea and attach any file. It appears on the other device the moment both are open.

## Install

**Windows.** Run `build\windows\x64\runner\Release\midad.exe` (or the H11 shortcut on the Desktop / Start menu). Keep the whole `Release` folder together. The first time it runs, Windows Firewall asks about network access: allow **Private networks**.

**Android (Galaxy S23+).** Copy `build\app\outputs\flutter-apk\app-release.apk` to the phone, open it, and allow "Install unknown apps" for your file manager when asked.

## Link the two

1. On the computer, click the status line under the title, then **Show the code**.
2. On the phone, tap the status line, then **Scan the code**.

Both devices must be on the same Wi-Fi. The QR code works once and expires after 3 minutes.

## How it behaves

- **Saving.** Pages save as you type, on each device separately.
- **Syncing.** Changes sync live while both apps are open. Pages written while apart sync the next time both are open.
- **Files.** Every file keeps its original bytes, format and name.
- **Deleting.** Deleting a page removes it from **that device only**, and the other device keeps its copy.
- **Translation.** Arabic ⇄ English, **free with no key**: Google Translate by default, MyMemory as a backup. For the best free quality, add a free DeepL API key (500,000 characters a month, deepl.com/pro-api) in Settings. Claude is optional and uses your own key. If one service fails, the next takes over automatically. The translation is saved with the page and shows which engine made it, so both devices see it. Text is sent to the chosen service to be translated.
- **On the computer.** The window is small, like a pocket notebook. Closing it hides it to the tray so syncing continues, and **Ctrl+Alt+M** opens it from anywhere. Settings → *Start with Windows* starts it in the tray at login.

## Security design

| Layer | What it uses |
|---|---|
| Transport | Noise Protocol `IK` with X25519, ChaCha20-Poly1305 and SHA-256 (the WireGuard family). Mutual authentication, forward secrecy, fresh keys every connection |
| Pairing | `IKpsk1` with a 256-bit single-use secret in the QR code. The phone pins the computer's public key |
| Device keys | Sealed by the OS: DPAPI on Windows, an AES-256-GCM key in the Android Keystore. Excluded from Android backups |
| Discovery | LAN probes are HMAC-signed. Only the paired computer answers |
| Hardening | 6 s handshake timeout, 4 concurrent handshakes max, 5 failures from one IP = 5-minute ban, 64 KB frame cap, strict JSON validation, sanitized file names, SHA-256 checked on every received file |

## Verification

```
flutter test --concurrency=1                  # 77 tests: sync, 15 attacks, edge cases, translation, assistant
dart run tool/noise_vectors.dart > v.json
python tool/noise_interop.py v.json           # byte-for-byte match with the independent `noiseprotocol` library
```

## Rebuild

```
flutter build windows --release
flutter build apk --release --target-platform android-arm64
python tool/make_icons.py                     # regenerate all icons
```

`android/midad-release.jks` and `android/key.properties` are the signing key. Back them up. Without them, later versions can't install as updates over this one.

