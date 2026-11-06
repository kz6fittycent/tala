# Tala

Renamed from Sema on 2026-11-04: the snap name `sema` was taken. The user registered `tala` (Old Norse "to speak"). Older notes below say Sema.

Unofficial snap of the official Nextcloud Talk desktop client (nextcloud/talk-desktop). It repackages Nextcloud's unmodified Linux ZIP. There is no app code here: to change app behavior, contribute upstream.

Status is kept in this file.

## Recipe notes
- Version and ZIP sha256 are pinned in `snap/snapcraft.yaml`.
- The ZIP's top directory is mode 700, so `chmod -R a+rX app` in override-prime is required.
- The client hides its startup setting on Linux. `sema.autostart on|off|status` and the launcher right-click actions provide it.
- No NVIDIA env workaround is needed (tested on RTX 2080, Wayland, gpu-2404).
- Testing: build with `snapcraft pack`, `sudo snap install --dangerous`, then connect browser-sandbox, camera and audio-record by hand. `--remote-debugging-port=9222` exposes GPU and sandbox state over CDP.
- Build on skyfire only with at least 20G free on `/`, then `snapcraft clean`.

## Status (2026-11-04)
Local build of 2.3.3 works, nothing published or committed. Verified: launch, sandbox on, GPU on, WebGL, devices listed, dark theme reported, autostart file written.

Needs the user signed in: tray, background start, real login autostart, notifications, call, Wayland screen share, update prompt.

## Before publishing
The user wants to refine this further first. Do not post to Nextcloud until they say so.

- Snap Store auto-connect requests: browser-sandbox (allow-sandbox), camera, audio-record.
- Icon is Nextcloud's Talk logo: must be replaced with an original one before any public release.
- Register the name, set grade stable, add the workflows, tell upstream on nextcloud/talk-desktop#913.
- Trademark: the user pasted a summary of the rules on 2026-11-04 (not the page text; nextcloud.com is unreachable from skyfire). No "Nextcloud" in the name, executable, icon, marketing graphics or domain; factual description use is fine if independence is clear. Open question for Nextcloud when the user is ready: the unmodified binary is named "Nextcloud Talk" and the app shows Nextcloud branding.

## Open refinements
- Tray icon registers once signed in (confirmed over D-Bus). Close-to-tray behavior is still untested.
- Confinement blocks `org.gnome.Mutter.IdleMonitor.AddIdleWatch`, which upstream's Flatpak allows for idle status. Automatic away status may not work.

## Layout and branding findings (2026-11-04, proposal, not built)
- Default window is hard-coded 1400x900 in upstream `src/talk/talk.window.js`, then remembered.
- Chat list hides because `@nextcloud/vue` `useIsMobile` treats under 1024 CSS px as mobile. A nav toggle reopens it.
- Upstream supports branded builds: `.overrides/build.config.json` renames the executable and window title, and `isBranded` turns off the GitHub update prompt.
- Proposed: build from source with overrides, the icon and a small layout patch, instead of repackaging the ZIP. Awaiting the user's decision.

## DIRECTION CHANGE (2026-11-04): Flutter rewrite
The user chose an original Flutter client with basics only: chat, audio calls, video calls. No backgrounds. Everything above about repackaging is superseded for the final app; the installed ZIP snap is only a local comparison. The old webapp failed because an underlying tool kept changing and then died, so keep critical dependencies few.

Findings: flutter_webrtc 1.6.3 (MIT, Linux/Mac/Windows, active; open Linux bugs include PipeWire screen-share crash and a crash with more than 8 ICE servers). Neon `talk_app` has chat, no calls, unpublished, AGPL. pub `nextcloud` 9.0.0 is AGPL, last published 2026-03. Talk signaling docs: spreed `docs/internal-signaling.md`, `docs/call.md`; strukturag `docs/standalone-signaling-api-v1.md`. Android client's `signaling/` and `webrtc/` are a reference. Test server: Nextcloud 34.0.5, HPB, call E2EE off.

Proposed next step, awaiting go-ahead: Linux call prototype against the user's server and phone before any UI work.

## Prototype status (2026-11-04)
Flutter Linux call prototype in `lib/`; only dependency is flutter_webrtc 1.6.3 (pinned). Build: `flutter build linux --release`. Local check with no server: `build/linux/x64/release/bundle/tala --selftest` (camera + mic loopback, passed: 119 frames in 8s on RTX 2080 + Wayland; camera took about 8s to open, worth watching). Log: `~/.config/tala-prototype/log.txt` (no secrets or SDP). Prototype stores the app password in `~/.config/tala-prototype/credentials.json` mode 600: use the keyring in the real app.
External signaling only; internal signaling, chat, screen share and packaging are not built. Real call test with the user's phone is pending. Not committed; no git repo yet. Old ZIP recipe is in `packaging-archive/`; the local `sema` snap is still installed.

## Camera freeze (fixed 2026-11-04)
The "force quit or wait" prompt was the UI thread blocked during camera start, not a crash; earlier unexplained exits at that step were probably the same prompt, unproven. libwebrtc makes 195 VIDIOC_TRY_FMT calls at about 42ms each on the Logitech QuickCam 3000, past GNOME's 5s check-alive limit. `third_party/flutter_webrtc` is a patched copy (see its TALA_PATCHES.md, wired in with `dependency_overrides`): longest UI stall dropped from about 8s to under 90ms. Camera still takes about 8s to start, so the UI needs a visible state for it. Confirm no prompt with the user.

Still open: no two-way call yet. Recipients don't ring: Tala joins with the same API and silent=false as the Android app, so server notifications should fire, but delivery isn't confirmed. Tala also plays no caller-side ring tone. Debug launcher: `tool/run-debug.sh` writes `~/.config/tala-prototype/crash.txt`. Don't touch the camera or rebuild while the user is in a test call.

## Milestone (2026-11-04)
Two-way audio and video confirmed by the user, Tala to a browser on the same server (external signaling). The silent browser ring was on the other side (no audible ring from the official iPhone app either). Tala has no incoming-call handling yet: next major item.

## Repo (2026-11-06)
Own local git repo on `main`, no remote. Nothing pushed. Prebuilt libwebrtc is left out: the plugin's CMake downloads it at the version in `third_party/flutter_webrtc/third_party/libwebrtc_version.ini` (checksum in TALA_PATCHES.md; CMake doesn't verify it, and the build fails if that release disappears). Older notes saying "not committed" or "no git repo" are out of date.

## Chat, first slice (built 2026-11-06, user confirmed sending and receiving both ways)
`lib/src/chat.dart` holds the model and `ChatThread` (long poll, paging, sending, read marker); `lib/src/chat_view.dart` holds the screens, with no new dependencies. Conversations and chat sit side by side down to 720 wide, then one pane at a time. Tapping a conversation now opens chat; calls start from its header. Reads never move the read marker: only `chatMarkRead` does, and only while the app reports resumed. `tala --chat-check` is a read-only server check that logs counts and message kinds, never names or text. It parsed 292 real messages with no failures. Unit and widget tests pass with a fake server. Not sent or marked read against the real server by me.
Not built: Markdown, avatars, message search, tray, upload progress and cancel, drag and drop, editing or deleting messages. Call join/left system messages all show, which may be noisy. Focus: Linux does report it; the log showed `app: inactive` and `app: resumed` changing during use on 2026-11-06.

## Icon (chosen by the user 2026-11-06)
A weathered Ansuz (ᚨ) cut into flat blue `#0082C9`. The Old English rune poem glosses its name as "mouth" and calls it the source of language (that gloss is debated), which suits a name meaning "to speak". `tool/make_icon.py` generates `assets/icon/tala.png` and `tala-512.png`, plus flat `tala-small-*.png` for tray and small sizes, because texture is lost below about 32px. Not yet wired into the window, tray or a desktop file. Tiwaz was tried first and dropped: it reads as an up arrow at tray size and is in the ADL hate symbol database as the "Tyr rune". My search found no ADL entry for Ansuz, but it wasn't exhaustive, so recheck before public release. Ask Nextcloud about the shared blue along with the other trademark question.

## Tray (proposed, awaiting the user's OK)
Plan: native code in `linux/runner` using libayatana-appindicator (needs `libayatana-appindicator3-dev`, and a snap must ship the library), no pub packages. `tray_manager` and `window_manager` moved onto the young `nativeapi` in late 2026 with several releases a week; `system_tray` was last released in April 2023.

## Chat, second slice (built 2026-11-06)
User confirmed on the real server 2026-11-06: replies, reactions, uploads, image previews, and a desktop popup appearing when unfocused and clearing when the conversation is opened. Not confirmed: no popup while the conversation is open and focused.
Desktop notifications (`lib/src/chat_alerts.dart`, `lib/src/desktop_notify.dart`) come from the server's own chat notifications, so its settings decide what alerts. Nothing pops up for notifications from before startup or for the open, focused conversation. Reading a conversation in Tala deletes its server notifications, clearing them on the user's other devices. Replies, reactions (six quick choices, no full picker), file upload and image previews are in `chat.dart`, `chat_view.dart` and `nc_api.dart`. Uploads go to the capability's folder (`/Talk`, flat, ignoring `conversation-subfolders`) with `If-None-Match: *`, so they never overwrite; a retry after a failed share doesn't re-upload. New dependency: `file_selector` (Flutter team), only for the attach button. Automated tests use a fake source and a loopback HTTP server; I don't send, react or upload on the user's account. Not tested in a snap: file picker confinement. No click action on notifications: Wayland can't raise the window. `log.txt` records `app: <state>` lifecycle changes.

## Incoming calls test (2026-11-04, confirmed by the user 2026-11-06)
Real call from a second tester: rang, Accept worked with them already in the call, audio and video both worked. Still untested: Decline, ring stopping when the caller hangs up or the user answers elsewhere, a long call (these need a second person). The user hung up that call themselves, so the `not_allowed` on a subscriber re-request isn't a dropped call. Fixed 2026-11-06, awaiting a real call to confirm: the "waiting for others" status overwriting "In call with N other(s)", and `_requestOffer` starting a retry timer during `hangUp` (a participant update arrived after the peer was dropped).

## Incoming calls (built 2026-11-04)
`lib/src/incoming_calls.dart` polls notifications every 4s with ETag, confirms with `/call/{token}/notification-state` (200 ringing, 201 missed, 404 joined), then `main.dart` shows Accept/Decline and `lib/src/ringer.dart` plays `assets/sounds/ring.wav` (own synthesized tone) via pw-play plus notify-send. Unit tests in `test/`. Known gaps: only rings while Tala is open (no tray yet); window can't raise itself on Wayland; older Talk without notification-state isn't handled (check the `call-notification-state-api` capability); Ringer is Linux-only and a snap must ship pw-play or equivalent; accepting when the other side is already in the call is untested.
