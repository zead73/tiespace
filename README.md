# tiespace

A human-driven **TUI client for the [Cyberspace](https://api.cyberspace.online) API**, written in Free Pascal (FPC 3.2.2).

Cyberspace is a small human social network. Its API Terms explicitly permit a
"personal client (TUI, mobile, desktop) that a real user drives" and forbid
bots, scraping, and AI-driven agents. tiespace is built to fit the first
description: **you** trigger every post, reply, and message; there is no
automation, no background scraping, and real-time updates come from the
server's push stream rather than polling loops. A client-side rate limiter
mirrors the API's documented limits.

## Status

A working, human-driven client. Confirmed against a live account.

**Auth** — in-TUI login (`Q` logs out to it; reads the password from `~/.cs-pw`,
remembers the email), session restore, token refresh, `0600` credential file.

**Read / write (social)** — press `?` in the feed for the full keybinding list
- feed (paginated `GET /v1/posts`); `c` new entry, `d` delete your own
- thread view: **selectable** entry + replies; `c` reply (to the entry or to a
  specific reply, nested); `d` delete your own entry or reply; `p` author
  profile; `i` view post images (shells out to `chafa`)
- compose: multi-line UTF-8 editor, `Ctrl+G` review + confirm, rate-limited
- notifications (`n`): list, unread badge, mark-read / mark-all, open the thread
- profile view (`p`): bio, stats, links, the user's entries; `f` follow
- search (`/`): users, entries and replies — opens a hit's thread or profile
- topics (`t`): browse topics, read the entries filed under one
- bookmarks: `b` bookmark an entry, `B` open the list (open / remove)

**Real-time (M3)**
- cIRC (`C`): room list, live message stream (RTDB SSE, background thread),
  send + IRC slash-commands, scrollback, live online-users panel + presence
  heartbeat
- C-Mail (`M`): conversation list, start new by username, live DM stream, send,
  mark-read, and typing indicators (both directions)

**Not yet built**: guilds; unfollow; in-room cIRC image viewer; chat-message
delete; entry title / topics / NSFW fields in the composer.

## Build

Requires: `fpc` 3.2.2, system OpenSSL 3, and wide ncurses (`ncursesw`).

```bash
make app       # builds bin/cyberspace (the client)
make spike     # bin/spike_login   (M0 transport check)
make session   # bin/session_test  (session/refresh harness)
```

Run `./bin/cyberspace` after logging in once (see below).

The `crtbeginS.o` / `crtendS.o` linker warnings from FPC on Arch are harmless;
the binary links and runs.

## Architecture

Layered, with everything below the UI independent of the TUI toolkit:

```
program cyberspace           entry: cthreads first, event loop
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
  help, NSFW handling, theming/keybindings

## Layout

```
Makefile
src/
  cyberspace.pas          program entry (restore session -> feed)
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
