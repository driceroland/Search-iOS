# Sync

How Search on iPhone and Search on the Mac share open tabs, pins, bookmarks
and a few settings. Both apps follow this page exactly; change it in both
or not at all.

Off by default on both. Turned on in Settings ("Sync with iCloud").

## Where

- CloudKit container `iCloud.com.officecommun.search`, the **private**
  database: the person's own iCloud. Nothing goes through a server of ours
  and nobody but the person can read it.
- One custom zone: `Search` (owner: current user).
- `CKSyncEngine` on both sides (iOS 17+, macOS 14+).

## Records

One record type, `Item`. Its record name says what it holds:

| Record name | Holds (JSON) | Written by |
|---|---|---|
| `device.<device-uuid>` | `DeviceTabs`: this device's open tabs | that device only |
| `pins.<space-uuid>` | `[PinDef]`: one space's pins, in order | any device |
| `bookmarks` | `[Bookmark]`: the whole tree | any device |
| `spaces` | `[Space]`: the Mac's spaces | the Mac |
| `settings` | `SharedSettings` | any device |

Fields of every `Item`:

- `encryptedValues["data"]`: `Data`, the JSON. End-to-end encrypted.
- `at`: `Date`, when the device that wrote it changed it. Not encrypted;
  it says nothing about the content.

No other fields, ever: a field in production can't be taken back. New
things get new record names, not new fields.

## Shapes

The Mac's own `Codable` types, so its files and the records are the same
JSON. Unknown keys are ignored on read; missing optional keys are nil.

```
PinDef        { id: UUID, letter: String, home: String, title: String, name: String? }
Bookmark      { id: UUID, title: String, url: String?, children: [Bookmark]? }   // url nil = folder
Space         { id: UUID, name: String, colour: Int, icon: String?, ... }        // the Mac's Space
DeviceTabs    { name: String, platform: "ios" | "macos", at: Date, tabs: [{ url: String, title: String }] }
SharedSettings{ engine: String?, custom: String?, look: String? }                // Engine / Look raw values
```

- Dates are JSONEncoder's default (seconds since 2001, a number).
- The first space is `00000000-0000-0000-0000-000000000001`; the iPhone shows
  that space's pins unless another is chosen.
- `DeviceTabs.tabs`: ordinary web pages only, no pinned tabs (pins travel as
  pins), **never private tabs**. The Mac sends every window's tabs of every
  space as one list.

## Rules

- **Latest wins, per record.** A change sets `at` to now. A record that
  arrives with an older `at` than the local one is ignored and the local
  one is sent again. A `serverRecordChanged` conflict keeps whichever has
  the newer `at`.
- **Joining merges.** The first time a device turns sync on, it fetches
  everything first. Pins (per space) and bookmarks already on the device
  are added to what's in iCloud (matched by `id`, then by address) and the
  union goes up. Settings: iCloud's win. Nothing is written over before
  that first fetch.
- **No echo.** Each app keeps the last JSON it wrote or read per record, in
  its own canonical encoding (sorted keys), and sends only when the new
  JSON differs.
- **Turning sync off** deletes this device's `device.<uuid>` record, so its
  tabs leave the other devices. Everything else stays.
- **"Delete Search's data from iCloud"** deletes the zone, for every device.
- **History, passwords, site data, private tabs: never synced.**

## Where this lives

- iPhone: `Sources/Sync.swift` (engine, shapes, bookmarks, the two lists).
- Mac: to be written by the Mac session, on this page.
