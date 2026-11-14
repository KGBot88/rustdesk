# RustDesk Pad: drive your PC with a handheld's controller

This is a personal fork of [RustDesk](https://github.com/rustdesk/rustdesk) (AGPL-3.0) for the
**AYN Thor**. The Android app gets a controller layer, so the handheld's built-in sticks and buttons
work as the remote PC's mouse and keyboard. It should also work with any Android gamepad.

It installs as **RustDesk Pad** (`com.carriez.flutter_hbb.pad`) **next to** the normal RustDesk app,
which stays as it was. The controller layer is only active inside a remote session. Everywhere else,
buttons behave normally.

## Button map

| Control | Remote PC action |
|---|---|
| Right stick | Move the mouse (deadzone, speeds up the further you push) |
| R3 (click right stick) | Precise cursor on/off (30% speed) |
| RT (R2) | Left click. Hold RT and move the stick to drag |
| LT (L2) | Right click (hold for right-drag) |
| Left stick | Scroll (up/down and left/right) |
| L3 (click left stick) | Middle click (hold for middle-drag) |
| D-pad | Arrow keys (repeat while held) |
| A | Enter |
| B (tap) | Undo (Ctrl+Z) |
| B (hold half a second) | Esc |
| X | Backspace (repeats while held) |
| Y (tap) | Open the on-screen keyboard (always opens, never closes it by mistake) |
| Y (hold half a second) | Close the on-screen keyboard |
| Double-tap the screen | Fit the whole PC monitor into the space above the toolbar, taskbar included (undoes pinch zoom) |
| R1 / L1 | Next / previous monitor (cycles through all monitors; numbers match RustDesk's own monitor buttons) |
| Start (tap) | Windows key (Start menu) |
| Select (tap) | Alt+Tab (switch to the last window) |
| **Hold Select + Start for 1 s** | Controller mouse mode on/off (also: the controller icon in RustDesk's bottom toolbar) |
| Android Back (from the pad) | Swallowed, so you can't leave the session by accident |
| Home, volume, power | Unchanged (Android keeps them) |

The A/B/X/Y labels follow Android's key codes. If your Thor is set to the Nintendo layout, A and B
(and X and Y) may be swapped.

Tuning values (speeds, deadzone, curve, repeat rate) sit at the top of
`flutter/lib/mobile/widgets/gamepad_controller.dart`.

### On-screen keyboard on the Thor
The keyboard always worked. **The Thor opens Android's keyboard on its bottom screen**, so if
you're watching the top screen it looks like nothing happened. Press Y (or RustDesk's keyboard
button) and type on the bottom screen.

Typing is kept in sync with the PC:
- The text strip above the keys shows what you've typed since the keyboard opened (or since the
  last Enter). Upstream RustDesk filled it with "1111..." helper text; this fork's helper text is
  invisible.
- Backspace (Gboard's or the pad's X) deletes in the strip and on the PC together.
- Autocorrect and suggestions work. When Gboard changes a word, the fix is sent to the PC too
  (upstream ignored those changes).
- The pad's Backspace (X) and Enter (A) also update the strip. Enter and pad Undo (B) start the
  strip fresh because the PC text changed in a way the keyboard can't see.
- The strip can't show text that was already on the PC, or follow you if you click somewhere else
  on the PC.

An open keyboard normally swallows controller buttons. This fork catches pad buttons before
the keyboard does (`GamepadPreImeFrame`), so Y closes it again and every button keeps working.

### Leaving a session
The pad's Back button is swallowed during a session. To leave, tap the screen to show
RustDesk's toolbar and press X.

### Controller mouse mode on/off
Switch it with **Select + Start held for 1 second**, or tap the **controller icon** in the session's
bottom toolbar (white = on, faded = off). A quick tap of Select or Start still does its normal job,
and fires when you let go.
- **On** (default): the button map above.
- **Off**: the controller does nothing on the PC. B and Back act as normal Android Back, and Home
  and volume work as always. Select+Start still switches the mode back on.
The app remembers your choice for next time.

## What changed (small on purpose, so it's easy to re-apply)
- `flutter/android/.../GamepadBridge.kt` (new): takes the controller's sticks and buttons
  before Flutter or Android see them, but only while a session is open.
- `flutter/android/.../MainActivity.kt`: 9 lines that hand events to the bridge.
- `flutter/lib/mobile/widgets/gamepad_controller.dart` (new): turns sticks and buttons into remote
  mouse moves, clicks, scroll, keys and monitor switches.
- `flutter/lib/mobile/pages/remote_page.dart`: starts and stops the controller with the session,
  plus a keyboard toggle, invisible helper text and a full-diff soft keyboard (autocorrect works).
- `flutter/android/app/build.gradle` + `AndroidManifest.xml`: app id `.pad` and the label "RustDesk Pad".
- `.github/workflows/thor-android.yml` (new): builds only the signed arm64 APK.

## Build
Pushing to `thor-gamepad` (or *Actions → Thor Android arm64 → Run workflow*) builds a signed
APK on GitHub Actions. That's about 1 hour the first time and faster once the caches warm up.
Download the artifact `rustdesk-pad-<version>-aarch64-signed`.

The signing key never lives in this repo. It's stored as the Actions secrets `ANDROID_SIGNING_KEY`,
`ANDROID_ALIAS`, `ANDROID_KEY_STORE_PASSWORD` and `ANDROID_KEY_PASSWORD`. Keep the original
keystore file. With a different key, Android refuses to update the installed app (you'd have to
uninstall it first).

## Rebuild after an upstream RustDesk update
1. `git fetch https://github.com/rustdesk/rustdesk.git tag <NEW_TAG> --no-tags`
2. `git checkout -b thor-gamepad-<NEW_TAG> <NEW_TAG>`, then
   `git cherry-pick <first-fork-commit>^..thor-gamepad` (or rebase `thor-gamepad` onto the tag).
3. If `remote_page.dart` or `MainActivity.kt` conflict, re-add the marked
   `rustdesk-controller` lines. The two new files rarely conflict.
4. In `thor-android.yml`, copy `env:` values (Flutter, NDK, vcpkg, VERSION) and the steps of
   `build-rustdesk-android` from the new upstream `flutter-build.yml` if they changed.
5. Push the branch, run the workflow, and install the APK over the old one with
   `adb install -r <apk>`. Same key, so your settings stay.
