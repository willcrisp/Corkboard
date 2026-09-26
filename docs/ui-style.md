# In-game UI style

Forever's default interface is the modern retail look: flat, plain frames. Corkboard should look like part of the game, so it's built from Blizzard's own frame templates and leaves colour to the things the game already colours. The mockup sources are in `docs/mockups/`.

## Principles

- **Blizzard templates first.** Use the stock templates so frames inherit the game's look (and any UI skin the player runs):
  - `PortraitFrameTemplate` or `ButtonFrameTemplate` for the main window
  - `InsetFrameTemplate` for the recessed panels
  - `UIPanelButtonTemplate` for buttons
  - `SearchBoxTemplate` and `InputBoxTemplate` for text fields
  - bottom panel tabs for Notes, Members and Settings
  - `StaticPopupDialogs` for confirmations
  - `GameTooltip` for tooltips and link hovers
  - the minimal scrollbar and ScrollBox for the lists
- **Neutral by default.** Colour only comes from:
  - gold headings (`NORMAL_FONT_COLOR`);
  - item and quest links, which carry their own quality colours;
  - class-coloured names for online members (offline members are grey, like the guild roster);
  - a small muted tag square on each note.
- **Game fonts.** Headings, labels and buttons use `GameFontNormal` / `GameFontHighlight` (Friz Quadrata). Note text uses `ChatFontNormal` (Arial Narrow) so it reads like chat and MRT notes. The mockups use Marcellus and PT Sans Narrow as stand-ins.
- **Feedback the WoW way.** Sync state goes in a grey status line at the bottom of the frame. Warnings are yellow text. Confirmations are StaticPopups. One-off events can print a line to chat, prefixed with a gold `Corkboard:`.

## Reference values (mockups)

| Use | Value |
|---|---|
| Heading text | `#ffd100` (NORMAL_FONT_COLOR) |
| Body text / highlight | `#ffffff`, note text `#e6e6e6` |
| Secondary / disabled text | `#9d9d9d` |
| Frame background | `#1b1a18` |
| Inset background | `#0f0e0d`, border `#34302b` |
| Note card | `#1f1d1a`, border `#36322c`; hover border `#6b624f` |
| Note tags (muted) | amber `#9a7a3c`, blue `#4f6f92`, green `#5d7d4c`, rose `#8f5563`, violet `#6d5c8f` |
| Status dots | synced `#4f9a47`, syncing `#5a8cc0` (hollow), paused `#b8903a`, behind `#b8663a`, idle `#7a7a7a` |

In game these come from the templates and font objects wherever possible. Only the note tags and status dots are Corkboard's own colours.

## Screens

1. **Board view**: portrait frame with the board list inset on the left, a 2-column note grid on the right, a search box, a New Note button, a status line, and bottom tabs.
2. **Note editor**: small button frame with a multi-line input, a "shift-click to link" hint, a character counter, a tag picker, and Delete / Cancel / Save buttons.
3. **Members tab**: the invite string (selected, "Ctrl+C to copy", since addons can't write to the clipboard), a Rotate Secret button, cloud and guild sync checkboxes, and a roster table.
4. **Popups**: join by invite, remove a member (rotates the secret), and an expired invite.
5. **Sync states**: status line variants, a yellow alert strip, chat output, and the minimap button tooltip.
6. **Debug (`/cork debug`)**: stats list, 32-bucket diff grid, peers table, message log.

## Phase 1 build notes

What the first in-game build does differently from the mockups, and why:

- **No bottom tabs yet.** Members and Settings hold invites, roster and sync options, which arrive in Phase 2. The Notes view is the whole window until then.
- **Board list footer:** New creates a board; Rename and Delete act on the selected one. Join arrives next to New in Phase 2.
- **Five tags, no "No tag" swatch.** A note always has a colour (1–8 in the data, §6), so there's no untagged state to pick. New notes default to amber.
- **Card chrome** is a flat 1px backdrop in the note-card colours above, the one place Corkboard draws its own frame colour. Everything else is a Blizzard template.
- **Edit and Delete** appear on a card when it's hovered, in place of its age, as in the mockup.

## Phase 2 build notes

- **Three bottom tabs, Notes, Members and Gear.** The mockup's Settings tab isn't built: the only settings so far are the cloud and guild checkboxes, which the Members mockup already shows. The tab template is `PanelTabButtonTemplate`, falling back to `CharacterFrameTabButtonTemplate` on clients without it.
- **Board list footer:** two rows, New and Join, then Rename and Delete.
- **Gear tab** (design.md §9.1): like the Members tab it replaces the note grid in the inset. A `UICheckButtonTemplate` option ("Post my new rare and epic gear to this board") sits above a striped list of "Name equipped [item]" rows, each with its age on the right in `GameFontDisableSmall`. The item links are live (tooltip on hover, click-through), as on note cards. No mockup; it reuses the Members tab's list styling.
- **Members tab:** it replaces the note grid in the right-hand inset, so the board list stays visible. The invite box is a read-only `InputBoxTemplate` (typing puts the invite back) that selects itself on focus for Ctrl+C. Rotate Secret shows for the owner only, and so do the remove buttons in the roster.
- **Status line:** the dot is hollow (a 4×4 frame-coloured square over the 6×6 dot) for "Syncing", "Connecting" and "Nobody online". The label is white and its detail grey; idle states grey both.
- **Alert strip:** yellow text on a dark strip along the bottom of the notes inset, for "N notes behind" (with a Reload button) and for paused sends with messages queued.
- **Debug panel** (`/cork debug`): a `ButtonFrameTemplate` window with the stats list, a 8×4 bucket grid against the member most recently heard from, the peers table, and the last 12 log lines. It refreshes every second while open.

## Optional extras

- **Flat skin.** An ElvUI-style variant (1px black borders, `#1a1a1a` background, narrow font) for players who run flat UIs. It's a setting, not the default.
- **Pinned overlay.** A read-only, click-through, lockable text overlay of one board, modelled on the Method Raid Tools note window, for glancing at mid-raid.
