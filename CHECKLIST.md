# Check-up

Run before every build that goes onto a phone. Every transition is recorded
on the simulator and looked at frame by frame, not judged from a still:

```bash
tools/rec.sh start NAME        # in the background; stops with:
tools/rec.sh stop NAME         # 30 fps frames + strips in /tmp/search-ios-rec/NAME
python3 tools/motion.py /tmp/search-ios-rec/NAME     # where it moves, single-frame jumps
python3 tools/strip.py /tmp/search-ios-rec/NAME 40 59   # those frames, numbered
```

What counts as a failure, in any frame:

- something that appears or disappears in one frame (a band, the pill, the
  count, a shadow, a blur) instead of moving or fading with the rest;
- layout that moves when nothing asked it to (a page's fixed button, the
  page under a card);
- a card that isn't the page as it was on screen, scaled evenly (cropped,
  re-laid out, scrolled differently, a band over its content);
- content passing under the pill or the blur that the page meant to keep
  clear (fixed bars and buttons);
- an opaque band anywhere the page should show (top, bottom);
- a sheet or field that ends up anywhere but at rest, or springs the wrong
  way.

Notes on reading the frames: `simctl io recordVideo` drops frames when the
simulator is busy, so during fast motion every other frame repeats the one
before and `motion.py` reports "jumps" on alternate frames. Check those by
eye: a real jump changes the picture, a dropped frame only delays it. The
sites' own carousels and marquees move too; they are the sites'.

Pages used: nor.ma (dark top, bottom fixed "Get 10% off", photos),
logosystem.co (light top, sign-up modal with a form), news.ycombinator.com
(long page of text), en.wikipedia.org (article, Reader), example.com.

## States and transitions

| # | What | How it's checked |
|---|---|---|
| 1 | Launch, tabs restored | first frames: the front tab's picture, then its page, no white flash; only the front tab loads |
| 2 | Launch, no tabs | the field is up on an empty page, the breath under it |
| 3 | Open the field (tap pill) | the pill turns into the field, one element, nothing left behind |
| 4 | Close the field (tap page, drag down, Go) | field turns back into the pill; keyboard leaves at once (device only) |
| 5 | Typing, suggestions, completion | suggestions above the field, first one taken, completion greyed after the caret |
| 6 | Go: address and search | address loads; words search with the chosen engine |
| 7 | Walk to the next tab | page follows the finger, neighbour's picture beside it, lands, live page takes over without a change |
| 8 | Walk back | same, the other way |
| 9 | Walk past the first tab | the page gives, springs back |
| 10 | Walk past the last tab | a new tab |
| 11 | Walk let go short | springs back |
| 12 | Sheet: tap the count | card shrinks from the page exactly as it was, band with it; sheet rises |
| 13 | Sheet: drag up from the pill | follows the finger; let go: opens or falls back |
| 14 | Sheet: tap the page to close | card grows back to the page, band with it, nothing pops at the end |
| 15 | Sheet: drag down from a row / the room / the foot | follows; let go: closes |
| 16 | Sheet: pull up past rest | gives a few points, no more |
| 17 | Row: swipe left / right | closes / pins; the word under it; the sheet stays |
| 18 | Row: tap | that tab, sheet closes |
| 19 | Private tab | from the sheet; glasses in the pill and the row; nothing written down |
| 20 | Settings | opens from the gear, Done closes, every switch takes effect |
| 21 | Find bar | from the hold menu; pill steps aside; back when the bar goes |
| 22 | Share | share sheet with the page |
| 23 | Reader / Leave Reader | the article; the page again |
| 24 | Hold menu | rises from the pill; tap outside puts it away |
| 25 | Pill folds / unfolds while scrolling | follows the scroll; page's fixed elements don't move at all |
| 26 | Rotation | iPhone: portrait only in v1 (the layout isn't drawn for landscape) |
| 27 | Dark mode | every surface dark; switching while open |
| 28 | Page with fixed bottom elements | above the pill and the blur, open or folded |
| 29 | Dark-top page / light-top page | band behind the clock readable; card and walk carry it |
| 30 | Long page | scrolls under the pill to the end; the end clears the pill |
| 31 | Form page | the field in the page raises the keyboard; the pill stays at the bottom under it |
| 32 | Download | Save to Files; a tab that only held the file closes |

## Last run

See the bottom of this file; each run lists what passed, what didn't, and
the frames looked at.

### Run of 16 Oct 2026 (iPhone 17 simulator, iOS 26.2)

Recorded and stepped through at 30 fps: `sheet`, `sheet3` (open and close by
tap), `sheetg` (lift from the pill, drop from a row), `fold` (scroll down and
up on nor.ma), `walk`, `walk2`, `walk3`, `field4` (open and close), `close`,
`close2`, `launch` (launch, hold menu), `hold`.

Found and fixed in this run:

- **Card not the page** (12–15): pictures taken with `drawHierarchy` or
  `snapshotView`, and even WebKit's `takeSnapshot` used as it came, kept
  showing the live page, unscaled, at its place on screen, so the card was a
  window onto the page rather than a picture of it. Now WebKit's snapshot,
  copied into a bitmap of its own and fitted by width from the top. Checked:
  the card is the page scaled to 0.92 at x 48 px, mean difference 0.4/255
  once the 8 % dim is allowed for; two screenshots two seconds apart are the
  same picture.
- **Band behind the clock** (12, 14, 29): part of the card, scaled with it,
  there on the way back; nothing appears at the end (`sheet3` 158–177,
  222–241).
- **Fixed elements moving with the fold** (25, 28): one bottom inset, the
  open pill's, never changed by the fold; nor.ma's "Get 10% off" stays put
  through the fold and the unfold (`fold` 90–109, 140–159).
- **Walk landing** (7, 8): the landed picture was still 4 % small when the
  live page took over, a jump of the whole page; the shrink now follows the
  distance from the nearest resting place (`walk` 52–71 before, `walk2`
  1–20 after, `walk3` 162–191).
- **Field closing** (4): the field and the dim left in one frame; they're
  always present now and fade on the keyboard's curve, and the address stays
  in the field while it fades (`close` 160–173 before, `field4` 206–215
  after; opening `field4` 151–160).
- **Hold menu closing** (24): left in one frame; now scale and fade
  (`launch` 266–275 before, `hold` 144–153 after).
- **Rotation** (26): iPhone is portrait only (the layout isn't drawn for
  landscape); iPad keeps every orientation.

Passed, frames looked at: 1 (`launch` 156–210: launch screen, the tab's
picture, a fade to the live page), 3, 4, 7, 8, 11 (`walk` 196–210), 12, 13,
14, 15, 16, 17, 18, 24, 25, 28, 29 (nor.ma dark top, logosystem light top).

Passed as stills earlier today, not recorded this run: 5, 6, 19, 20, 21, 22,
23, 27, 30, 32. Not checkable on the simulator: 4's keyboard timing, 31 (no
soft keyboard), the blur's look on a real screen.

Known and left: a page that animates on its own (a carousel) goes on under
its picture while the sheet is up; closing by tap re-takes the picture just
before the card grows back, but closing by a drag can still show the
carousel's slide change in the frame the live page takes over.
