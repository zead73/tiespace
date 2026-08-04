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

### Thread watching — `thread_reply` notifications for threads you follow
Auto-watched when you reply or are @mentioned; also manual watch/unwatch.
- [ ] `csapi`: watch status (`GET /v1/posts/:id/watch`), watch (`POST`), unwatch (`DELETE`), list (`GET /v1/watches`)
- [ ] thread view: `w` watch/unwatch toggle + a watched/unwatched indicator
- [ ] watched-threads list view (open a thread from it)
- [ ] rate rule: `watch` = 10/min, 100/day
- [ ] README + this checklist

### Settings — read/write account preferences
`GET` / `PATCH /v1/settings`.
- [ ] `csapi`: GetSettings / UpdateSettings
- [ ] `csmodels`: `TSettings` covering the documented fields
- [ ] `ui/cssettings.pas`: view + toggle fields (notifications per-type, `filterNSFW`,
      `showFollowerCount`, `hideImagesInFeed`, `hideAudioInFeed`, `autoWatchOnReply`,
      `defaultPublicPost`, `timeDisplayFormat`, `imagePixelSize`, muted/followed topics, …)
- [ ] rate rule: `settings` = 2/min, 15/day
- [ ] README + this checklist

## Client-side polish (no new API — just UI/rendering)

- [x] **Add colours to the new help screen** — cyan frame, bold-cyan section headers, bold-yellow key shortcuts, blue title band, highlighted `[bracketed]` context keys
- [ ] **Read-side NSFW handling** — blur/gate/collapse NSFW entries in the feed and
      threads (we already set the flag on compose and show a `[NSFW]` label); honor the
      `filterNSFW` setting once Settings lands
- [ ] **Richer markdown rendering** — inline bold/italic/headings/lists/links in thread
      bodies (today content is entity-decoded and lightly cleaned for summaries only)
- [ ] **Slash-command help** — an in-client reference for cIRC slash-commands
      (sourced from the API `/commands` section); commands already pass through to the server
- [ ] **Theming** — selectable colour themes; can persist server-side via `iconTheme`/Settings
- [ ] **Keybindings** — remappable keys; can persist via `keyboardBindings`/`keyboardPreset`/Settings

## Notes on ordering

- **Settings + read-side NSFW + watching** interlock: the settings screen exposes
  `filterNSFW` and `autoWatchOnReply`, so building them near each other avoids rework.
- **Notes** is the most self-contained (a standalone view that reuses the composer),
  so it's the easiest single win to start with.
