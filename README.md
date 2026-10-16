# Search for iPhone

A small, fast, quiet web browser for the iPhone, by [Office Commun](https://officecommun.com). The Mac's [Search](https://github.com/driceroland/Search), rebuilt for a thumb.

> In development. Nothing is on the App Store yet.

---

## What it is

A page, edge to edge, and one pill at the bottom: where you are, and how many pages are open. There is no toolbar, no start page, no feed, no account. Everything else is a gesture on that pill.

It uses **WebKit**, the engine every iPhone already has. It is not a copy of the Mac app: nothing is shared between the two, by design. Each device is its own browser.

## How it works

- **Tap the pill** to type. An address takes you there, words search. It finishes addresses from your own history and sends nothing anywhere until you press Go.
- **Drag the pill sideways** to walk your tabs. The page follows your finger.
- **Swipe the pill up** for every tab: pinned pages as letters at the top, one line for each of the others. Swipe a line away to close it.
- **Hold the pill** for the rest: back and forward, reload, share, find on page, reading mode, ads on or off for the site, pin.
- **Ads and trackers are blocked before they load.** On by default, off per site if something breaks.
- **Private tabs** keep their own cookies and leave nothing behind.

## What it doesn't do

On purpose: no sync, no account, no cloud, no AI, no telemetry, no analytics, no crash reports. Your tabs and history are small files on your iPhone and nowhere else. The only things that leave it are the pages you ask for.

## Building

Open `Search.xcodeproj` in Xcode 26 or later and run the `Search` scheme. iOS 18 or later.

## License

[MIT](LICENSE). © 2026 Office Commun.
