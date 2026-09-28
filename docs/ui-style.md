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
3. **Members tab**: the invite string (selected, "Ctrl+C to copy", since addons can't write to the clipboard), a Rotate Secret button, cloud and guild sync checkboxes, and a roster table (Name, Role, Level, Last Seen, Sync). Level is the level the member was at when last heard from, carried in their HELLO; it's blank until one arrives.
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

- **Six bottom tabs, Notes, Members, Gear, Professions, Quests and Players.** The mockup's Settings tab isn't built: the only settings so far are the cloud and guild checkboxes, which the Members mockup already shows. The tab template is `PanelTabButtonTemplate`, falling back to `CharacterFrameTabButtonTemplate` on clients without it.
- **Board list footer:** two rows, New and Join, then Rename and Delete.
- **Gear tab** (design.md §9.1): like the Members tab it replaces the note grid in the inset. A `UICheckButtonTemplate` option ("Post my new rare and epic gear to this board") sits above a striped list of "Name equipped [item]" rows, each with its age on the right in `GameFontDisableSmall`. The item links are live (tooltip on hover, click-through), as on note cards. No mockup; it reuses the Members tab's list styling.
- **Professions tab** (design.md §9.2): the same layout as the Gear tab, with a `SearchBoxTemplate` at the top right beside the "Share my recipes on this board" checkbox. Rows show "Leatherworking 47/75 · 8 recipes" (or, while searching, a live recipe link) on the left and who in `GameFontDisableSmall` on the right. Profession rows are buttons with the quest-title highlight and a plus / minus toggle (`Interface\Buttons\UI-PlusButton-Up` / `UI-MinusButton-Up`, greyed for a profession with no recipes) on the left; an open one lists its recipes as live links, indented under it. With no search, the note left of the search box says "Click a profession to see its recipes." The web app does the same with a `+` / `−` box. A second row holds the filters: "Level" in `GameFontNormalSmall`, two 30-wide `InputBoxTemplate` number boxes with a dash between, then `UICheckButtonTemplate` boxes for Cloth, Leather, Mail and Plate. Recipe rows show "Level 25 · Leather" in `GameFontDisableSmall` in a 120-wide column left of who. When a search is cut at 200 rows, a `GameFontDisableSmall` note left of the search box says so.
- **Quests tab** (design.md §9.3): the "Share my quest log with this board" `UICheckButtonTemplate` option across the top. Below it on the left, a 150-wide list of the members sharing a log, styled like the board list (name in `GameFontHighlight`, class-coloured when online and grey when not; "N · M shared" under it in `GameFontDisableSmall`; the gold wash on the chosen one). On the right, the member's name and quest count in `GameFontNormal`, a grey line saying how current the list is and how many quests you share, an "Only quests I'm on too" checkbox, then striped rows: the ready-check tick (`Interface\RaidFrame\ReadyCheck-Ready`) on quests you're on too, the live quest link, and the level on the right. Above the rows sit two top tabs, **Quest log (N)** and **Completed (N)** (`PanelTopTabButtonTemplate`, falling back to `TabButtonTemplate`), with the filter checkbox right-aligned on the same line, its label to its left. Rows are buttons with the quest-title highlight when they can open. A quest with a known chain has the Professions tab's plus / minus toggle on the left and "Part N" in `GameFontDisableSmall` in a 46-wide column left of the level; an open one lists the earlier steps indented under it, after a `GameFontDisableSmall` caption, each marked with `ReadyCheck-Ready` (you've done it), `ReadyCheck-Waiting` (it's in your log) or `ReadyCheck-NotReady` (you haven't). A 60-wide "2h ago" column sits left of "Part N". On Completed, a chain's rows are joined by a 2px grey line with a 4px dot on each row, in the toggle's column. The web app draws the same with small tabs over the list and a `+` / `−` box. No mockup.
- **Players tab** (design.md §9.4): **Avoid** and **Good players** `UICheckButtonTemplate` filters on the left of the top row, a `SearchBoxTemplate` and an **Add Player** button on the right. Under that, a one- or two-line `GameFontDisableSmall` description of what the tab is for (who sees the notes, and that they show on tooltips and warn when an avoided player joins your group). Below, striped rows of variable height: the ready-check cross (`Interface\RaidFrame\ReadyCheck-NotReady`) or tick (`ReadyCheck-Ready`), the name in `GameFontHighlight` followed by the verdict in the game's red (`RED_FONT_COLOR`) or green (`GREEN_FONT_COLOR`), "author · age" on the right in `GameFontDisableSmall` (replaced by Edit and Delete on hover, as on note cards), and the reason under the name in `ChatFontNormal` with live links. A `GameFontDisableSmall` count sits at the bottom left. The verdict colours are the game's own, so they don't break "neutral by default". No mockup.
- **Player note editor:** built like the note editor (`ButtonFrameTemplate`, no portrait): a **Character** `InputBoxTemplate` with a **Target** button, **Avoid** and **Good player** as a pair of `UICheckButtonTemplate`s that act as radio buttons, then **Why** in the same inset multi-line box as a note, with the hint, byte counter and yellow message under it, and Delete / Cancel / Save.
- **Unit tooltip:** player-note lines are added to `GameTooltip` as a double line (verdict in red or green, "author · board" in grey) and the reason wrapped in off-white.
- **Members tab:** it replaces the note grid in the right-hand inset, so the board list stays visible. The invite box is a read-only `InputBoxTemplate` (typing puts the invite back) that selects itself on focus for Ctrl+C. Rotate Secret shows for the owner only, and so do the remove buttons in the roster. Clicking a roster row opens that member's quest log on the Quests tab.
- **Status line:** the dot is hollow (a 4×4 frame-coloured square over the 6×6 dot) for "Syncing", "Connecting" and "Nobody online". The label is white and its detail grey; idle states grey both.
- **Alert strip:** yellow text on a dark strip along the bottom of the notes inset, for "N notes behind" (with a Reload button) and for paused sends with messages queued.
- **Debug panel** (`/cork debug`): a `ButtonFrameTemplate` window with the stats list, a 8×4 bucket grid against the member most recently heard from, the peers table, and the last 12 log lines. It refreshes every second while open.

## Web app build notes

The web app (design.md §7.4, `web/public/css/corkboard.css`) draws the same window in CSS, from the reference values above and the mockups:

- **Frames:** the portrait frame (the note icon in a ringed circle at the top left), the dark title bar with the gold title, recessed insets, the red-and-gold `UIPanelButtonTemplate` buttons, dark input boxes, gold-ticked check boxes, and the bottom tabs hanging under the frame. Popups are StaticPopup-style boxes; the editors are `ButtonFrameTemplate`-style windows with a red close button.
- **Fonts:** Marcellus for headings, labels, buttons and tabs, PT Sans Narrow for body and note text, self-hosted (SIL OFL, `web/public/fonts/`), as in the mockups.
- **Colour** comes only from what the game colours: gold headings, link colours from the note text (`|cnIQ<n>:` maps to the item quality colours), the note tags, the status dots, and the Players tab's red and green. Ready-check marks are drawn as a green tick and a red cross.
- **Links:** hovering (or tapping) a link shows a GameTooltip-style box: the name in the link's colour, the kind in blue, and the id in grey.
- **Title bar buttons:** a person icon on the right opens "Your name on notes" (the name notes are signed with). On a phone, a menu icon on the left opens the board list.
- **Phone layout** (720 px and narrower): the window fills the screen, the board list becomes a drawer, cards go to one column, Edit and Delete always show (there's no hover), the search box and New Note wrap under the board name, and the six tabs sit along the bottom edge, above the home indicator.
- **Only dark.** The game has no light UI, so neither does the web app.

## Optional extras

- **Flat skin.** An ElvUI-style variant (1px black borders, `#1a1a1a` background, narrow font) for players who run flat UIs. It's a setting, not the default.
- **Pinned overlay.** A read-only, click-through, lockable text overlay of one board, modelled on the Method Raid Tools note window, for glancing at mid-raid.
