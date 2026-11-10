# Tala

An original Flutter desktop client for Nextcloud Talk, Linux only, shipped as a snap. Renamed from Sema on 2026-11-04 because the snap name `sema` was taken; Tala is Old Norse "to speak". The repo is public: keep private details out of this file.

Status and decisions are kept in this file.

## Where things stand (2026-11-10)
0.6.1 is on stable (promoted 2026-11-07). On `main`, not yet released (pubspec still says 0.6.1): read ticks, call joined/left messages hidden, drafts kept across restarts, upload progress and Cancel, drag and drop, a reaction picker, presence (heartbeat, status dots, own status, Do not disturb holding popups), an unread badge on a call's closed chat button, adding groups and teams, conversation descriptions and polls. See "Added 2026-11-10" below. Wiki edits for them are committed in a scratchpad clone only, not pushed.

The user's direction (2026-11-10): untested areas (calls with more than three people, a real no-HPB server across networks, real federation) are left to reports from users in the field.

Not built, by choice so far:
- Typing indicators: they travel over signaling, and Tala only connects to signaling during calls. Joining the room just to view chat would change how the server treats the user (active sessions), so it needs thought first.
- Voice messages: they show as file links. Playing them needs an audio decoder, and recording needs mic capture to a file; both mean new dependencies.
- Search jumping into the live chat (see Message search).

## Background
The user first repackaged Nextcloud's official desktop ZIP as a snap, then chose on 2026-11-04 to write an original Flutter client instead: chat, audio and video calls, no call backgrounds. The old webapp they used failed because a tool it depended on kept changing and then died, so keep critical dependencies few: pub packages are a last resort, and native code in `linux/runner/` (tray, keyring, file drop) is preferred over young plugins.

Staying on Flutter, Linux only (the user's decision, 2026-11-07); don't build for Mac or Windows. The wiki is a separate repo (`tala.wiki.git`); keep it current with features.

Trademark (settled by the user 2026-11-07): keep "Nextcloud" out of the name, executable, icon, marketing graphics and domain; factual description is fine if independence is clear. With the user's approval, an FYI comment went on nextcloud/talk-desktop#913 (independent client, not affiliated, links to the repo and wiki).

References: spreed `docs/internal-signaling.md`, `docs/call.md`, Talk's `openapi-full.json` (some endpoints aren't in the docs); strukturag `docs/standalone-signaling-api-v1.md`; the Android client's `signaling/` and `webrtc/`.

## Building and checking
- `flutter build linux --release --no-tree-shake-icons`. The flag is required: on Flutter 3.47.4 the trimmed icon font lost one used icon per build (cause not established; widget tests can't catch it). The full font adds about 1.6 MB.
- Builds need `libayatana-appindicator3-dev`, `libsecret-1-dev` and `libpipewire-0.3-dev`. None are installed on skyfire, so full local builds fail there; tests and the analyzer work (`flutter test`, `flutter analyze lib test tool`). A single runner file can be compile-checked with `g++ -std=c++17 -c <file> -Ilinux/flutter/ephemeral $(pkg-config --cflags gtk+-3.0)`.
- Snaps build on GitHub only. `tool/get-flutter.sh` pins Flutter by version and commit for the snap and CI.
- `tool/group_check.dart` runs Tala's real API code against a throwaway Nextcloud (see its header). On 2026-11-10 it ran on a `nextcloud:35` container (35.0.2, Talk 25.0.7) at `127.0.0.1:8089`, named `tala-group-check`, with alice, bob and carol, carol also in group `checkgroup`. It refuses anything but `http://127.0.0.1`. Never point it at a real account.
- `tool/mesh-check/up.sh` starts a no-HPB server plus Talk's web client under Playwright for call checks (see Internal signaling).
- `tool/make_screenshots.dart` draws real widgets with invented people into `docs/screenshots/`: `XDG_CONFIG_HOME=$(mktemp -d) flutter test tool/make_screenshots.dart`. Never use real people or conversations. Dates change daily, so every run changes most pictures. The wiki keeps copies in its `images/`.
- Developer modes: `tala --selftest` (camera and mic loopback, no server), `--chat-check` (read-only server check, logs counts only), `--report-check`, `--keyring-selftest` (private D-Bus session only, or it loads the real account), `--tray-selftest`, `--badge-test`, `--test-chime`, `--test-ringback`, `--crash-test`, `--call-check`. `tool/run-debug.sh` writes `~/.config/tala/crash.txt`.
- Config folder is `~/.config/tala` (or `$XDG_CONFIG_HOME/tala`): `settings.json`, `drafts.json`, `log.txt` (rotates to `log.previous.txt`), `fatal.log`, `pending/` reports.
- Don't touch the camera or rebuild while the user is in a test call.

## Repo and releases
Public at https://github.com/kz6fittycent/tala, branch `main`. Commit freely; pushing needs the user's approval. Commits use the GitHub noreply address set in this repo's git config. Prebuilt libwebrtc isn't committed: the plugin's CMake downloads it at the version in `third_party/flutter_webrtc/third_party/libwebrtc_version.ini` and checks `sha256_linux_x64`.

Workflows copy XBTune's, without Windows. `snap-builds.yml` tests, builds and uploads the .snap. `call-for-testing.yml` publishes to candidate when the repo variable `TALA_STORE_PUBLISH` is `true` and pubspec's version is newer than the store's (`tool/bump_version.sh`). `promote-to-stable.yml` runs on a `/promote` comment from the owner or a collaborator, in the `promote-stable` environment: `main` only, no required reviewer, because the comment is the approval (the user's decision, 2026-11-07; a reviewer rule made 0.6.1's promote wait). `security-rebuild.yml` rebuilds stable. The user watches builds themselves.

Store: the listing has the icon and screenshots, `donation:` is in the recipe, and the license is AGPL-3.0-or-later. A release doesn't update the store's license field: the user changes it in the snapcraft.io dashboard. No store auto-connect requests (the user's call, 2026-11-06): users connect camera, audio-record and password-manager-service by hand.

Licenses: `LICENSE` holds the AGPL v3 text, then a section stating or-later and the FFmpeg notice. libwebrtc contains FFmpeg (LGPL) and H.264 code; the user decided on 2026-11-07 that H.264 stays, as with HandBrake. `tool/make_webrtc_licenses.py` writes `assets/licenses/libwebrtc.txt` and `lib/src/licenses.dart` registers it. When `binary_version` changes, rerun that script, recheck its list, and update the release and FFmpeg revision at the end of `LICENSE` (the revision comes from `m150_release`'s DEPS, not a record of the build).

## Snap
`snap/snapcraft.yaml`: core24, `extensions: [gnome]` (the user's choice), Ubuntu 24.04 with clang, Ubuntu's dev packages, the extension's SDK variables cleared. Confinement facts from AppArmor profiles on skyfire: `unity7` allows the ayatana tray and the dock signal; `audio-playback` has no PipeWire rule, so a snap rings with `paplay`; the dock URI is `application://<instance>_tala.desktop`; start at login writes `$SNAP_USER_DATA/.config/autostart/tala.desktop` through the `autostart:` key. A second launch finds the running copy through an abstract socket (`claim_snap_instance` in `my_application.cc`), because a dbus slot needs a human store review. The host OS can't be read without `system-observe`, so reports use a `Kernel:` fact.

Confirmed working from the snap by the user: sign-in, keyring, two-way calls, screen share, file picker, links, chime, ringback, start at login. Not checked in a snap: drag and drop (files outside home would need `removable-media` or similar).

## Calls
`lib/src/call.dart`, `call_layout.dart`, `signaling.dart`, `internal_signaling.dart`. External signaling (HPB) and internal signaling (mesh) both work; the user confirmed normal HPB calls on 0.3.1 and two-way calls to browsers, phones and other Talas.
- Camera: libwebrtc makes about 195 `VIDIOC_TRY_FMT` calls at about 42ms each on skyfire's Logitech QuickCam 3000, so its camera takes about 8s (a modern webcam opens in 0.65s). `third_party/flutter_webrtc` is a patched copy (see `TALA_PATCHES.md`, wired in with `dependency_overrides`) that keeps this off the UI thread. The user accepts the slow camera as hardware; the "super laggy" report was that camera too.
- Join-first: `Call.start` opens media alongside joining, joins with audio and video flags, rings, then publishes when the camera is ready. Flags are set up front on purpose: the web client ignores later flag changes for someone it has already seen (`previousUsersInRoom` in spreed's `webrtc.js`). Late publishers rely on the signaling server holding a stream request (10s default `mcu timeout`); Android sends one request only. If media fails, Tala stays receive-only and corrects the flags with `PUT call/{token}`.
- Layout: remote video fills the space in cover mode (`FillGrid`); with chat open (default, saved as `callChatOpen`), video shares the window with a 340-wide column of own camera above chat, or chat goes below under 760 wide. The chat is a normal `ConversationPane` with `showHeader: false`, kept by a GlobalKey; the main pane comes off screen so only one thread polls. While the chat is closed its button shows the room's unread count from the 15s room poll.
- Ringback (`Ringback` in `ringer.dart`) plays only if nobody was in the call at the start, until someone joins, at most 60s.
- Calls are "a bit glitchy at first" with the camera on; no evidence yet on why. Three `processing_failed` signaling errors in issue #10's log on 0.3.1 were never investigated.
- `flutter_webrtc` caps ICE servers at 8 on desktop (`iceServers` in `nc_api.dart`).

### Internal signaling
For servers with no HPB. `internal_signaling.dart` is the transport (long poll and POST on `signaling/{token}` with the room-join cookies). Mesh logic follows the web client: the larger session id offers, the waiting side re-offers every 10s, someone with no streams is only ever offered to. Everything arriving before media is ready is held; `freshMeshMessages` keeps each person's newest offer, keyed by person and roomType. Messages are handled one at a time so a candidate never overtakes its offer. Checked with `tool/mesh-check/up.sh` (Talk 24.0.7) and the real web client under Playwright, using `tala --call-check` with `TALA_CHECK_*` env: offering, answering, no media, Tala to Tala, three people, a slow camera. Before audio checks, route libwebrtc to virtual nodes (`pw-cli create-node adapter` with `support.null-audio-sink`, `PULSE_SOURCE`, `PULSE_SINK`). The test server's SQLite gives a 500 on most first polls, so retries start at 1s. Federated calls need the HPB; Tala refuses them otherwise.

### Screen share
Receiving (0.5.1): Tala answers `roomType` `screen` offers and drops them on `unshareScreen`, when the sharer leaves, and on hang up. `ScreenStage` shows the screen uncropped with people's videos below.
Sending (0.6.0, own screen shown to the sharer since 0.6.1): the plugin runs the portal ScreenCast session itself over GDBus and feeds PipeWire frames (BGRx to I420) into `CreateCustomVideoSource`, one picker per share, reporting sharing, cancelled and stopped to Dart (Tala's patch in `TALA_PATCHES.md`; `lib/src/screen_share.dart`). libwebrtc's own route opened two pickers and couldn't report cancel. Through the HPB, `_publishScreen` offers to the user's own session, then `sendoffer` goes to everyone in the call and later joiners; without it, each person gets a connection offered with `broadcaster` set. `SharingBanner` shows Stop sharing, since GNOME showed no indicator. Watch for: very low frame rates or a Start that never answers (seen once in the prototype, not repeated). Window capture through libwebrtc's own `getSources(types: [Window])` crashed; the native route offers windows safely.

### Incoming calls
`lib/src/incoming_calls.dart` polls notifications every 4s with ETag, confirms with `/call/{token}/notification-state` (200 ringing, 201 missed, 404 joined), then shows Accept and Decline and plays `assets/sounds/ring.wav`. Rings while Tala runs, including from the tray; a hidden window opens for it, though Wayland may not raise it. Older Talk without `call-notification-state-api` isn't handled. The user confirmed Decline, ring stopping, a long call, Android, answering with the slow camera, Quit during a call and ringing a hidden window on 2026-11-06 (their word; no item-by-item record).

## Chat
`lib/src/chat.dart` (model, `ChatThread`: long poll, paging, sending, read marker) and `lib/src/chat_view.dart` (screens). Conversations and chat sit side by side down to 720 wide. Reads never move the read marker: only `chatMarkRead`, only while the app is resumed. Reading in Tala deletes that conversation's server notifications. Confirmed by the user: sending and receiving, replies, reactions, uploads, image previews, editing, deleting, popups.
- Right-click or the hover "More actions" button: Reply, Copy text, Edit (own non-attachment, non-poll messages; mentions go back to `@"id"`), Delete (own, or others' for moderators outside one-to-ones). Tala shows the server's refusal rather than hiding options.
- Uploads go to the capability's folder (`/Talk`, flat) with `If-None-Match: *`, so nothing is overwritten; a retry after a failed share doesn't re-upload. `file_selector` (Flutter team) is used only for the attach button.
- Notifications (`chat_alerts.dart`, `desktop_notify.dart`) come from the server's chat notifications. Nothing pops up for the open, focused conversation or while Do not disturb is set. No click action: Wayland can't raise the window.
- Message sound: `assets/sounds/message.wav` (glass steps, from `tool/make_chimes.py`) as a `sound-file` hint on `notify-send`, so the notification server plays it and its Do Not Disturb applies. At most one per 3s, none while ringing or in a call; "Message sound" in the menu turns it off.
- Logging: never add names or message text to `log()`, since `maskReportText` can't recognize them. Search terms sit in request paths, which masking doesn't cover, so people search, mention search and message search log only the status.

### Markdown
`lib/src/markdown.dart` is Tala's own small parser. Only messages the server flags `markdown: true` are formatted (as the web client's `useExtendedMarkdown`). Bold, italic, strikethrough, inline and fenced code, links (http and https only, through `safeUrl`), headings, quotes, lists, task lists, rules. Tables stay as typed; images aren't drawn. `blocks` is the layout, `segments` the flattened text for previews and Copy text, `editSource` the raw source. Unclosed delimiters are remembered so hostile messages don't go quadratic.

### Mentions
Typing `@` at a word's start lists matches from `GET chat/{token}/mentions` (without the user, at most 5); arrows, Enter or Tab, click, Escape. The composer shows `@Maya Chen`; `PickedMentions` maps names to ids and sends `@"id"`. Picks are kept with the draft in `DraftStore`, so they survive restarts. A second person with the same name goes in as raw `@"id"`.

### Avatars
`lib/src/avatars.dart`. Only chosen user pictures (`X-NC-IsCustomAvatar: 1`) and raster room pictures are shown; everything else, including emoji and SVG room avatars, guests and federated people, gets a letter in the accent color (19px bold). User pictures recheck hourly, room pictures when `avatarVersion` changes; nothing is on disk.

### Message search
`lib/src/search.dart`: unified search (`search/providers/talk-message/search`), all conversations or one, 400ms pause, latest wins, "Show more" after a full page of 20. A result opens `MessageContextDialog` with up to 15 messages each side (`chat/{token}/{id}/context`) instead of jumping in the live chat, which could mean loading thousands of messages (my choice, flagged to the user). A server without `chat-get-context` shows "Couldn't load this message".

### Added 2026-11-10 (on `main`, unreleased, nothing seen by the user yet)
- Read ticks: `X-Chat-Last-Common-Read` from chat fetches (`chatLastCommonRead`). One tick sent, two read by everyone; members who joined through a group count, and the server omits the header when the user keeps read status private. Verified on Talk 25.0.7 by `group_check`.
- `call_joined` and `call_left` system messages are hidden; "Call ended" already lists who and how long.
- Drafts: `lib/src/drafts.dart`, `drafts.json`, mode 600, tied to `user@server`, saved a second after typing stops and on unfocus, quit and dispose.
- Uploads: `UploadControl` reports progress per flushed chunk and aborts the request on Cancel; a cancelled file is never shared.
- Drag and drop: `linux/runner/file_drop.cc` makes the Flutter view a GTK drop target (`text/uri-list`) and sends local paths on channel `tala/drop`; `lib/src/file_drop.dart` routes them to the newest open conversation and shows "Drop to send to …" while dragging. Folders are skipped. Compile-checked with g++ only: no full build has run it.
- Reactions: "More…" opens `lib/src/emoji_picker.dart`, a fixed set of about 250 common emoji in six tabs, drawn by the system font. No search.
- Presence: `lib/src/presence.dart`. A heartbeat (`user_status` API) every 5 minutes says online, or away after 5 unfocused minutes, and goes at once on return; the server applies it only while the user's own status is Online. Status (Online, Away, Do not disturb, Invisible) is in the menu. One-to-ones get the other person's status from `room?includeStatus=true`: a dot on the avatar and a line under the header. Tala's idle measure is window focus, because confinement blocks GNOME's IdleMonitor. A server without `user_status` (404) stops the heartbeat and hides the menu item.
- Groups and teams: `searchMembers` asks autocomplete for share types 0, 1 and 7; `addMember` takes a `Person` and sends its source (`users`, `groups`, `circles`). One-to-one search stays users only.
- Descriptions: "Name and description…" (was Rename…) edits both; `PUT room/{token}/description`; shown under a group's name in its header.
- Polls: `lib/src/polls.dart`. A message with a `talk-poll` parameter has `pollId` and shows a card; `PollDialog` votes (`optionIds`), changes a vote, shows results and lets the asker or a moderator end it; `CreatePollDialog` from a button by the composer in group and public conversations. Hidden results (`resultMode` 1) come back with empty votes until closed. Verified on Talk 25.0.7 by `group_check`.

## Conversations
- New conversation (a filled button atop the list): one-to-one via `core/autocomplete/get` and `POST room` roomType 1 with `invite` (deprecated by Talk for `participants`, but Android still uses it); "New group" (`NewGroupDialog`); "Invite someone without an account" (guest link).
- Groups (`lib/src/groups.dart`, confirmed by the user on 0.4.0): `MembersDialog` lists members for everyone; moderators of local conversations (`Room.canManage`) add, remove and promote. The server's list reloads after every change. Removals and moderator DELETEs take `attendeeId` in the query. Federated conversations get the read-only list.
- Guest links (`lib/src/guest_link.dart`, confirmed on 0.2.2): roomType 3 with optional password; link `<server>/index.php/call/<token>`; email invitations; Turn off link (`DELETE room/{token}/public`). Delete for everyone (always confirmed) is offered on local public rooms, and on groups the user can't leave, when `canDeleteConversation` is true. Never run it on the real account in tests.
- Remove chat is `DELETE room/{token}/participants/self`.
- Archive (`archived-conversations-v2`): options or right-click, with Undo; archived rooms sit in a collapsed "Archived (N)" section, which "Show archived" in the menu removes from Tala only. Never seen against real archived data.
- Federation: one local account; the local server proxies federated conversations. Pending invitations (polled each minute) show above the list; a globe marks federated rooms; no attachments there. None of it has run against a real federated conversation.

## App shell
- Tray (`linux/runner/tray.cc`, libayatana-appindicator, channel `tala/tray`; `tray_manager`, `window_manager` and `system_tray` were rejected for churn or age). Closing hides Tala while a tray host is connected, otherwise quits. Tray Quit hangs up a call first (3s in Dart, 5s in the runner). The library warns it's deprecated for libayatana-appindicator-glib; revisit when distributions ship that. "Start at login" (off by default) runs `tala --background`, which shows the window if no tray host appears in 20s.
- Dock badge: `com.canonical.Unity.LauncherEntry.Update` from `tray.cc`, only while unfocused, counting `dockUnread` (skips archived and muted). Confirmed by the user.
- Keyring (`linux/runner/keyring.cc`, channel `tala/keyring`, no pub package; `lib/src/account_store.dart`): one Secret Service item "Tala account" holding server, user and app password as JSON. Unavailable retries 5 times at 3s, then a Try again screen. Not verified: a dismissed unlock prompt giving the "locked" screen.
- Sign-in: Login Flow v2 in the browser; the user agent `Tala/<version>` is the device name. A 401 on the room list is confirmed with `GET cloud/user` before showing `SignInExpiredPage`, to avoid brute-force lockout. Change server signs in first, saves to the keyring, then revokes the old app password (`DELETE core/apppassword`); never test that on the real account.
- Menu (`lib/src/app_menu.dart`): account, status, Appearance (theme and six accents in `lib/src/app_colors.dart`), Message sound, Show archived, Start at login, Help (wiki), Report a problem, About (AGPL, independence, licenses), Support (Ko-fi only).
- Colors (the user's request, 2026-11-06: no AI-purple): default accent is the icon's `#0082C9`; `talaTheme` uses the fidelity scheme variant, and `_softened` replaces surfaces with soft grays tinted by the accent (dark 15% lightness, light 89%). Tests check contrast for every accent and keep visible roles off purple.
- Report a problem (`lib/src/report.dart`, `report_view.dart`, same design as XBTune's): relay Worker at `tala-bug-report.jimmy-tigert.workers.dev` (`relay/bug-report/`) turns reports into public issues labeled `user-report`; unsent reports wait in `pending/`. Masking covers hosts, URLs, room tokens, username, app password, emails, IPs and home folders. `linux/runner/fatal_signal.cc` notes native crashes in `fatal.log`. Confirmed by the user with issue #10.
- Icon (the user's choice, 2026-11-06): a plain white Ansuz (ᚨ) with chiseled edges on flat `#0082C9`, from `tool/make_icon.py`. Tiwaz was dropped for reading as an arrow and being in the ADL hate symbol database. Rechecked 2026-11-07: no Ansuz entry found at the ADL (strong, not exhaustive).

## Older notes
The repackaged-ZIP snap and its recipe are gone from this machine and the repo; nothing of it remains in use.
