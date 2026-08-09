# tiespace — M4 polish checklist

Everything through M3 plus discovery (feed, threads, compose, profiles, search,
topics, bookmarks, notifications, cIRC, C-Mail, guilds) is done. What remains is
the M4 "polish" bucket, tracked here so we can check items off as we land them.

## API-backed (endpoints exist; the client just doesn't use them yet)

### Notes — private notes with revision history ✅ done (feed key `N`)
Private to you; editing creates a new revision rather than overwriting.
- [x] `csapi`: get (`FetchNote`, `?revision=N`) / create / update (PATCH) / delete
      (list + revision history are read inline in the view)
- [x] `csmodels`: `TNote` + parser
- [x] `ui/csnotes.pas`: list → read (scrollable) → new / edit (reuse the composer) →
      revision history → view a past revision → delete
- [x] feed entry point (`N`)
- [x] rate rule — reused existing `note` (3/min, 30/day)
- [x] README + this checklist

### Thread watching — `thread_reply` notifications for threads you follow ✅ done
Auto-watched when you reply or are @mentioned; also manual watch/unwatch.
- [x] `csapi`: FetchWatchStatus (`GET /v1/posts/:id/watch`), WatchThread (`POST`), UnwatchThread (`DELETE`); list read inline by the view (`GET /v1/watches`)
- [x] thread view: `w` toggle + a `👁 watching` header indicator
- [x] watched-threads list view (`ui/cswatches.pas`, feed key `W`): rows resolve
      postId → "@author · summary" lazily; Enter opens, `x` unwatches
- [x] rate rule: `watch` = 10/min, 100/day
- [x] README + this checklist

### Settings — read/write account preferences ✅ done (feed key `S`)
`GET` / `PATCH /v1/settings`.
- [x] `ui/cssettings.pas`: toggle-and-save checklist — reads GET /v1/settings and
      PATCHes only changed fields (self-contained; no separate csapi/csmodels layer
      since these prefs are view-local). `Space` toggles, `s` saves in one request,
      discard-guard on quit with unsaved changes.
- [x] fields: the documented top-level booleans (`filterNSFW`, `autoWatchOnReply`,
      `defaultPublicPost`, `showFollowerCount`, `hideImagesInFeed`, `hideAudioInFeed`,
      `useLegacyMenuOrder`) + per-type notification switches read **dynamically** from
      the returned `notifications` object (sent back in full so a replace-PATCH is safe)
- [x] rate rule: `settings` = 2/min, 15/day
- [x] README + this checklist
- ~~complex fields (keyboardBindings/preset, iconTheme, muted/followed topics,
      imagePixelSize, timeDisplayFormat) left for the theming/keybindings items~~

## Client-side polish (no new API — just UI/rendering)

- [x] **Add colours to the new help screen** — cyan frame, bold-cyan section headers, bold-yellow key shortcuts, blue title band, highlighted `[bracketed]` context keys
- [x] **Read-side NSFW handling** — honours the `filterNSFW` setting (loaded into the
      session, kept in sync when Settings saves). Centralised `FeedSummary` masks NSFW
      rows to `[NSFW hidden]` across feed/profile/topics/guilds; the thread view gates an
      NSFW entry's title/body/images behind `x` reveal (and blocks `i` until revealed).
- [x] **Richer markdown rendering** — new `ui/csmarkdown.pas` renders decoded content
      into styled runs (bold, italic→underline, `code`, links, headings, `-`/`1.` lists,
      `>` quotes, `---` rules); CsUI gained a run/underline draw path (`TStyleRuns`,
      `DrawRuns`/`DrawStyled`) and the thread view draws bodies as styled runs. Parser is
      unit-tested (18 asserts).
- [x] **Slash-command help** — `/help` (or `/commands`, `/?`) in a cIRC room opens a
      scrollable static reference of the slash commands (intercepted client-side, posts
      nothing); status line hints `/help cmds`
- [x] **Theming** — 5 built-in colour themes (default/green/amber/magenta/mono) in CsUI;
      cycled from the Settings screen's top row, applied live, saved **locally**
      (`~/.config/tiespace/theme`) — not via the server `iconTheme`, which is the
      website's icon set, a different concept. Theme fns unit-tested.
- [ ] **Keybindings** — remappable keys; can persist via `keyboardBindings`/`keyboardPreset`/Settings

## Notes on ordering

- **Settings + read-side NSFW + watching** interlock: the settings screen exposes
  `filterNSFW` and `autoWatchOnReply`, so building them near each other avoids rework.
- **Notes** is the most self-contained (a standalone view that reuses the composer),
  so it's the easiest single win to start with.
