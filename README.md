# tiespace

A human-driven **TUI client for the [Cyberspace](https://api.cyberspace.online) API**, written in Free Pascal (FPC 3.2.2).

Cyberspace is a small human social network. Its API Terms explicitly permit a
"personal client (TUI, mobile, desktop) that a real user drives" and forbid
bots, scraping, and AI-driven agents. tiespace is built to fit the first
description: **you** trigger every post, reply, and message; there is no
automation, no background scraping, and real-time updates come from the
server's push stream rather than polling loops. A client-side rate limiter
mirrors the API's documented limits.

## Screenshots

![The feed](screenshots/tiespace-feed.png)

*The feed — the paginated post list you land on after login.*

![A thread](screenshots/tiespace-thread1.png)

*A thread — the entry with its title, topics and body, replies below, and the
`👁 watching` indicator in the header.*

![cIRC room list](screenshots/tiespace-chat1.png)

*cIRC — the room list, with per-room online counts and last activity.*

![A live cIRC room](screenshots/tiespace-chat2.png)

*cIRC — a live room: streamed messages, the online-users panel, `🖼` image
markers, and select mode (`Tab`) for acting on a message.*

## Status

A working, human-driven client. Confirmed against a live account.

**Auth** — in-TUI login (`Q` logs out to it; OPTIONAL reads the password from `~/.cs-pw`,
remembers the email), session restore, token refresh, `0600` credential file.

**Read / write (social)** — press `?` in the feed for the full keybinding list
- feed (paginated `GET /v1/posts`); `c` new entry, `d` delete your own
- thread view: **selectable** entry + replies with **rendered markdown** in
  bodies (bold, italic, `code`, headings, `-`/`1.` lists, `>` quotes, links,
  `---` rules); `c` reply (to the entry or to a specific reply, nested); `d`
  delete your own entry or reply; `b` bookmark the post; `f` report (flag) an
  entry/reply; `p` author profile; `i` view post images / image attachments
  (shells out to `chafa`); `w` watch/unwatch the thread (a 👁 marks a watched
  thread). Audio/jukebox attachments show as a numbered text line; `o` plays the
  first (or `1`–`9` picks a track when a post has several) in the **background**
  (shells out to `mpv` + `yt-dlp`) while you keep browsing — the feed header
  shows what's playing, and `o` there stops it
- compose: multi-line UTF-8 editor (new entries can add an optional title, up
  to 3 topics, and an NSFW flag), `Ctrl+G` review + confirm, rate-limited; all
  text inputs accept terminal paste (bracketed paste)
- notifications (`n`): list, unread badge, mark-read / mark-all, open the thread
- profile view (`p`): bio, stats, links, the user's entries; `f` follow/unfollow
- search (`/`): users, entries and replies — opens a hit's thread or profile
- topics (`t`): browse topics, read the entries filed under one
- bookmarks: `b` bookmark an entry, `B` open the list (rows resolve to the
  post's `@author · title`; open / remove)
- guilds (`g`): browse the guild directory, open a guild's forum; `c` start a
  thread, `m` list members, `J`/`L` join / leave (one guild at a time)
- notes (`N`): private, revisioned notes — `c` new, `e` edit (saves a new
  revision), `v` browse revision history, `d` delete
- watched threads (`W`): the threads you watch for replies; Enter opens one,
  `x` unwatches (watch/unwatch from inside a thread with `w`)
- settings (`S`): toggle account preferences — NSFW filter, auto-watch on
  reply, per-type notifications, feed/display switches; `Space` toggles, `s`
  saves all changes in one request. The top row is a local colour **Theme**
  (`Space` cycles default / green / amber / magenta / mono; applied live and
  saved to your config)
- NSFW filtering: with **Filter NSFW** on (Settings), NSFW posts read as
  `[NSFW hidden]` in every list, and an NSFW thread's title/body/images stay
  hidden until you reveal them (`x`, per thread)

**Real-time (M3)**
- cIRC (`C`): room list, live message stream (RTDB SSE, background thread),
  send + IRC slash-commands (`/help` shows the command reference), scrollback,
  live online-users panel (idle users shown asleep, `💤`) + presence heartbeat
  that reports your own activity; `/art` ASCII-art posts are base64-decoded and
  rendered verbatim; in select mode (`Tab`), `d` deletes your own message, `i`
  views a message's image, and `f` reports a message
- C-Mail (`M`): conversation list, start new by username, live DM stream, send,
  mark-read, and typing indicators (both directions)

**Not yet built**: the remaining M4 polish items — theming, remappable
keybindings.

## Build

Requires: `fpc` 3.2.2, system OpenSSL 3, and wide ncurses (`ncursesw`).

```bash
make           # builds the client and runs the tests (app + test)
make app       # just the client -> bin/tiespace
make test      # builds + runs the pure-function unit tests
make spike     # bin/spike_login   (M0 transport check)
make session   # bin/session_test  (session/refresh harness)
```

Run `./bin/tiespace` after logging in once (see below).

`make test` runs a no-network, no-terminal suite over the parsers, HTML-entity
decoding, the rate limiter, and the wcwidth/UTF-8 layout helpers; it exits
non-zero if anything fails. Needs a UTF-8 locale (as the client itself does).

If FPC can't locate gcc's C-runtime directory it emits harmless `crtbeginS.o` /
`crtendS.o` linker warnings; the Makefile normally finds it and suppresses them,
and either way the binary links and runs.

## Platforms

Native on **Linux** and the **BSDs** — anywhere with FPC 3.2.2, wide ncurses,
OpenSSL, and (optional) `chafa` for images plus `mpv` + `yt-dlp` for playing
audio attachments. There is **no native Windows build**: the UI
is built on ncurses and a few POSIX calls (`wcwidth`, Unix file-mode bits,
`fpSystem`), so on Windows you run it under **WSL**.

### Windows → WSL (Alpine, the small way)

Alpine is the lightest WSL distro that can build tiespace — a few MB of base
image, a few hundred MB once the compiler and libraries are added.

1. **Get Alpine on WSL** (WSL2; run `wsl --update` first). Install *Alpine WSL*
   from the Microsoft Store, or import the mini-rootfs / `.wsl` image from
   <https://alpinelinux.org/downloads/>:
   ```powershell
   wsl --install --from-file alpine-<version>-x86_64.wsl
   ```
2. **Install the build deps.** FPC lives in Alpine's `testing` repo, so enable
   `community` and `testing` in `/etc/apk/repositories`, then:
   ```sh
   apk update
   apk add fpc binutils musl-dev ncurses-dev ncurses-terminfo-base \
           openssl-dev chafa make git
   ```
   (`openssl-dev` is needed because FPC's OpenSSL unit loads the *unversioned*
   `libssl.so`, which only the `-dev` package provides.)
3. **Build and run:**
   ```sh
   git clone https://github.com/zead73/tiespace
   cd tiespace && make app && ./bin/tiespace
   ```

Images: if `chafa` reports *"unknown file format"* on a `.webp`, its Alpine build
lacks a WebP loader (as nixpkgs' does) — rebuild `chafa` with `libwebp`, or skip
image viewing.

**Caveats (I haven't tested the Alpine+musl combo).** FPC 3.2.2 does run on
Alpine's musl libc, but it's a less-trodden path than glibc. If a freshly built
binary won't start with a dynamic-loader error, add the musl→glibc loader alias:
```sh
ln -s /lib/ld-musl-x86_64.so.1 /lib64/ld-linux-x86-64.so.2
```
If Alpine proves fiddly, any mainstream **glibc** WSL distro (Debian/Ubuntu) is
the turnkey fallback — larger, but just:
`sudo apt install fpc libncurses-dev libssl-dev chafa make git`.

## Security & credentials

**Your password is never written to disk.** At login it is held in memory only
and sent to the API over HTTPS; nothing persists it.

What the client stores — all under `$XDG_CONFIG_HOME/tiespace/` (i.e.
`~/.config/tiespace/`), mode `0600`, outside this repo:

- `session.json` — the long-lived **refresh token** plus `rtdbUrl`, `username`,
  `userId`. This is a token (it's how you stay logged in), *not* your password.
- `last-email` — the email to pre-fill on the login screen.

`~/.cs-pw` is **optional and you create it yourself** — the client only ever
*reads* it, never writes it. It's an accessibility accommodation: if the file
exists, its contents are used as the password so you needn't type or paste it.
Without it you just type the password at the login screen. If you do use it,
`chmod 600 ~/.cs-pw`.

The one credential kept at rest in plaintext (at `0600`) is the refresh token in
`session.json` — standard for a CLI client, and it could be moved into the OS
keyring (libsecret) for stronger at-rest storage if desired.

## Architecture

Layered, with everything below the UI independent of the TUI toolkit:

```
program tiespace             entry: cthreads first, event loop
├── app/    session · config(XDG) · ratelimit     tokens, refresh, prefs
├── net/    http · sse · jsonutil                  transport, data/error envelope
├── api/    one unit per endpoint group            typed Pascal calls
├── model/  TEntry TReply TUser TGuild TMessage    records over parsed JSON
├── rt/     realtime — RTDB SSE manager            path-merge, presence, typing
└── ui/     core(ncursesw) · app(view stack) · markdown · views/*
```

- **net/http** (`src/net/cshttp.pas`) — wraps `TFPHTTPClient`; Bearer auth,
  JSON in/out, maps the `data` / `error {code,message}` envelope, and (M1)
  handles `429` backoff and `401` refresh-and-retry.
- **net/sse** (M3) — one `TThread` per RTDB stream; parses `event:`/`data:`
  frames into a thread-safe queue the UI loop drains. Token expiry closes the
  stream → refresh → reconnect.
- **app/session** — holds `idToken` / `refreshToken` / `rtdbUrl`; proactive
  refresh (~50 min) plus reactive on 401. Credentials persist as the long-lived
  `refreshToken` in a `0600` file under `$XDG_CONFIG_HOME/tiespace/`; the
  password is never written to disk.
- **ui** — ncursesw (handles UTF-8/emoji, resize, colour); a view stack over
  Feed → Thread → Compose → Profile → Notifications → Search → …

## Toolkit decisions

- **TUI:** ncursesw — best fit for the emoji/Unicode aesthetic on modern
  terminals (Kitty/Ghostty/WezTerm), matches the ncurses toolset already in use.
- **v1 scope:** core client first (feed, threads, compose, profiles,
  notifications, bookmarks), then discovery, then real-time chat.
- **Credentials:** XDG config, refresh token in a `0600` file.

## Milestones

- **M0** — transport spike · done
- **M1** — core client: login, feed + pagination, thread view, compose
  entry/reply, profiles, notifications + unread + mark-read, bookmarks; rate
  limiter, token refresh, config
- **M2** — discovery: search, topics, guilds, follows
- **M3** — real-time: RTDB SSE manager; cIRC rooms and C-Mail DMs (live +
  presence + typing)
- **M4** — polish: notes, settings, watches, richer markdown, slash-command
  help, NSFW handling, theming/keybindings — tracked as a checklist in
  [TODO.md](TODO.md)

## Layout

```
Makefile
src/
  tiespace.pas            program entry (restore session -> feed)
  net/cshttp.pas          transport: auth, JSON, data/error envelope, GET/POST/PATCH
  app/csconfig.pas        XDG paths + 0600 secret file helpers
  app/cssession.pas       login, refresh, persistence
  api/csapi.pas           shared fetchers (entry by id/slug, reply, unread count)
  model/csmodels.pas      TEntry/TReply/TNotification + entity decode + time/format
  ui/csui.pas             ncursesw core: colours, wcwidth layout, WrapText
  ui/csfeed.pas           feed view
  ui/csthread.pas         thread view
  ui/csnotify.pas         notifications view
  spikes/spike_login.pas  M0 transport check
  spikes/session_test.pas session/refresh harness
```

## License

MIT — see [LICENSE](LICENSE). © 2026 Zead.
