### Downloads

**`tiespace-x86_64.AppImage` — recommended.** One self-contained file with wide
ncurses and OpenSSL 3 bundled inside it, so it runs on essentially any current
Linux (glibc 2.34+ — Ubuntu 22.04+, Debian 12, RHEL/Alma/Rocky 9, Fedora, Arch,
openSUSE) with nothing to install:

```bash
chmod +x tiespace-x86_64.AppImage
./tiespace-x86_64.AppImage        # add --appimage-extract-and-run if FUSE isn't set up
```

**`tiespace-x86_64` — the bare binary, for the adventurous.** It bundles nothing,
so it only runs where the host already provides everything it links or loads:
wide ncurses (`libncursesw.so.6`), OpenSSL 3 *including the unversioned*
`libssl.so` *link* (usually the `openssl-devel` / `libssl-dev` package — FPC loads
OpenSSL by that name), and a recent glibc (2.34+). That lines up on a rolling or
freshly-updated system and is easy to get wrong anywhere else. The AppImage
carries all of it inside, so unless you specifically want the raw executable,
prefer the AppImage — it's a single file too, and it can't trip over a missing or
mismatched library.

Both look up the optional helpers `chafa` (images), `mpv` + `yt-dlp` (audio), and
`xdg-open` (opening links) on your `PATH`; install those if you want the features.
