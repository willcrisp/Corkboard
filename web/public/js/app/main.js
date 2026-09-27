// The Corkboard web app (docs/design.md §7.4): the board window from the
// game, in a browser. It signs in with a board's invite and a free-text
// name, keeps its boards in the browser, and syncs through the same API the
// desktop companion uses.

import { h, icon, ICONS } from "./dom.js";
import { Api } from "./api.js";
import { Boards } from "./boards.js";
import { openStorage } from "./storage.js";
import { ask, closeAll, confirm, noteEditor, playerEditor, popup } from "./dialogs.js";
import { renderTabs } from "./tabs.js";
import { age, boardName, count, explain, noteMatches, plural, webName } from "../model/view.js";
import { members, notes } from "../model/formats.js";

const TABS = ["Notes", "Members", "Gear", "Professions", "Quests", "Players"];
const POLL_CURRENT = 30; // seconds between syncs of the board on screen
const POLL_OTHERS = 300; // and of the rest
const PUSH_DELAY = 800; // ms after a local change

const now = () => Math.floor(Date.now() / 1000);

const ui = {
  tab: "Notes",
  query: "",
  drawer: false,
  tabState: {},
  installPrompt: null,
};

let boards;
let root;
const lastSync = new Map();
const pushTimers = new Map();

// Rendering ------------------------------------------------------------------------

// Re-renders without losing the focused field or its caret: elements that
// should keep focus carry a data-keep key.
function keepFocus(fn) {
  const active = document.activeElement;
  const key = active?.dataset?.keep;
  const sel = key && "selectionStart" in active ? [active.selectionStart, active.selectionEnd] : null;
  const scroll = [...root.querySelectorAll("[data-scroll]")].map((el) => [el.dataset.scroll, el.scrollTop]);
  fn();
  for (const [name, top] of scroll) {
    const el = root.querySelector(`[data-scroll="${name}"]`);
    if (el) el.scrollTop = top;
  }
  if (key) {
    const el = root.querySelector(`[data-keep="${key}"]`);
    if (el) {
      el.focus();
      if (sel) el.setSelectionRange(sel[0], sel[1]);
    }
  }
}

function render() {
  keepFocus(() => {
    root.replaceChildren(!boards.me || boards.list().length === 0 ? welcome() : windowFrame());
  });
}

function welcome() {
  const nameInput = h("input", { class: "field", "aria-label": "Your name", placeholder: "Your name, e.g. Will",
    value: boards.settings.name ? boards.settings.name.replace(/-Web$/, "") : "", autocomplete: "nickname",
    spellcheck: "false", "data-keep": "welcome-name" });
  const inviteInput = h("input", { class: "field", "aria-label": "Invite", placeholder: "CORK1:…", autocomplete: "off",
    spellcheck: "false", "data-keep": "welcome-invite" });
  const signed = h("div", { class: "grey small" });
  const error = h("div", { class: "warn small", role: "alert" });
  const join = h("button", { class: "btn", type: "submit" }, "Join Board");
  const preview = () => {
    const [name] = webName(nameInput.value);
    signed.textContent = name ? `Your notes are signed ${name}.` : "Add -Realm to post as your character, e.g. Will-Stormrage.";
  };
  nameInput.addEventListener("input", preview);
  preview();
  const form = h("form", { class: "dialog-body" },
    h("div", { class: "intro" }, "Read and write your Corkboard boards away from the game. Paste an invite from ",
      h("span", { class: "heading" }, "Members"), " in game (or ", h("code", {}, "/cork invite"), ") and pick the name your notes carry."),
    h("div", { class: "field-group" }, h("label", { class: "heading" }, "Your name"), nameInput, signed),
    h("div", { class: "field-group" }, h("label", { class: "heading" }, "Invite"), inviteInput),
    error,
    h("div", { class: "grey small" }, "Boards sync through your group's Corkboard server. What you post reaches the game when a member's companion syncs and they /reload."),
    h("div", { class: "dialog-foot" }, h("span", { class: "spacer" }), join));
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const [, nameReason] = await boards.setName(nameInput.value);
    if (nameReason) {
      error.textContent = explain(nameReason);
      return;
    }
    const [board, reason] = await boards.join(inviteInput.value);
    if (!board) {
      error.textContent = explain(reason);
      return;
    }
    render();
    syncNow(board.id);
  });
  return h("div", { class: "welcome frame" },
    h("div", { class: "portrait" }, icon(ICONS.note)),
    h("div", { class: "titlebar" }, "Corkboard"),
    form);
}

function statusFor(board) {
  const s = board.sync;
  const waiting = boards.pendingCount(board);
  const waitingText = waiting ? `· ${plural(waiting, "change")} waiting` : null;
  if (s.state === "refused") return { label: "Invite out of date", detail: "· ask a member for a new one", dot: "behind" };
  if (s.state === "offline") return { label: "Offline", detail: waitingText || "· showing the last copy", dot: "paused" };
  if (s.state === "error") {
    const detail = s.error === "rate_limited" ? "· too many requests, trying again soon" : `· ${s.error}, trying again soon`;
    return { label: "Sync failed", detail, dot: "behind" };
  }
  if (!s.at) return { label: "Syncing", detail: "· with the cloud", dot: "syncing", hollow: true, dim: true };
  const detail = waitingText || (board.sync.rejected ? `· ${plural(board.sync.rejected, "change")} refused by the server` : "");
  if (s.state === "syncing") return { label: "Syncing", detail, dot: "syncing", hollow: true };
  return { label: `Cloud synced ${age(now() - s.at)}`, detail, dot: "synced" };
}

function dot(status) {
  return h("span", { class: `dot ${status.dot}${status.hollow ? " hollow" : ""}` });
}

function boardList(current) {
  const items = boards.list().map((board) => {
    const status = statusFor(board);
    const detail = board.sync.state === "refused" ? "Invite out of date" : plural(notes(board).length, "note");
    const item = h("button", { class: "board-item", type: "button", "aria-current": String(board === current) },
      h("span", { class: "name" }, boardName(board)),
      h("span", { class: "detail" }, dot(status), detail));
    item.addEventListener("click", async () => {
      ui.drawer = false;
      ui.tabState = {};
      await boards.select(board.id);
      render();
      syncNow(board.id);
    });
    return item;
  });
  const join = h("button", { class: "btn small", type: "button" }, "Join");
  const rename = h("button", { class: "btn small", type: "button", disabled: !current }, "Rename");
  const leave = h("button", { class: "btn small", type: "button", disabled: !current }, "Leave");
  join.addEventListener("click", joinDialog);
  rename.addEventListener("click", () => ask({
    message: `Rename ${boardName(current)}`,
    value: current.meta ? current.meta.name : "",
    label: "Board name",
    note: "The new name shows for every member.",
    submit: async (value) => {
      const [, reason] = await boards.rename(current.id, value);
      return reason;
    },
  }));
  leave.addEventListener("click", () => confirm(
    `Leave ${boardName(current)}? It's removed from this device only; you can rejoin with the invite.`,
    "Leave",
    async () => {
      await boards.leave(current.id);
      render();
    }));
  return h("div", { class: "boards inset" },
    h("div", { class: "heading" }, "Boards"),
    h("div", { class: "board-list", "data-scroll": "boards" }, items),
    h("div", { class: "board-foot", style: { gridTemplateColumns: "1fr 1fr 1fr" } }, join, rename, leave));
}

function joinDialog() {
  ask({
    message: "Paste a Corkboard invite to join a board.",
    placeholder: "CORK1:…",
    label: "Invite",
    okay: "Join",
    submit: async (value) => {
      const [board, reason] = await boards.join(value);
      if (!board) return reason;
      ui.drawer = false;
      render();
      syncNow(board.id);
      return null;
    },
  });
}

function settingsDialog() {
  const install = ui.installPrompt
    ? h("button", { class: "btn small", type: "button", onclick: async () => {
      ui.installPrompt.prompt();
      ui.installPrompt = null;
    } }, "Install App")
    : null;
  ask({
    message: "Your name on notes",
    value: boards.settings.name || "",
    label: "Your name",
    okay: "Save",
    note: h("span", {}, "A name without a realm is signed -Web. Use Name-Realm to post as your character.",
      install ? h("div", { style: { marginTop: "10px" } }, install) : null,
      h("div", { class: "small", style: { marginTop: "10px" } }, boards.storage.persistent
        ? "Boards are kept in this browser."
        : "This browser won't keep boards after you close it (private window?).")),
    submit: async (value) => {
      const [, reason] = await boards.setName(value);
      if (!reason) render();
      return reason;
    },
  });
}

function openNoteEditor(board, note) {
  noteEditor({
    board,
    note,
    now: now(),
    onSave: async (text, color) => {
      const [, reason] = note
        ? await boards.editNote(board.id, note.id, { text, color })
        : await boards.addNote(board.id, text, color);
      return reason;
    },
    onDelete: async () => {
      const [, reason] = await boards.deleteNote(board.id, note.id);
      return reason;
    },
  });
}

function openPlayerEditor(board, note) {
  playerEditor({
    board,
    note,
    now: now(),
    onSave: async (name, verdict, reason) => {
      const [, why] = note
        ? await boards.editPlayer(board.id, note.id, name, verdict, reason)
        : await boards.addPlayer(board.id, name, verdict, reason);
      return why;
    },
    onDelete: async () => {
      const [, why] = await boards.deleteNote(board.id, note.id);
      return why;
    },
  });
}

function windowFrame() {
  const board = boards.current;
  const status = statusFor(board);
  const allNotes = notes(board);
  const shown = allNotes.filter((n) => noteMatches(n, ui.query));

  const head = h("div", { class: "window-head" },
    h("div", { class: "board-title", title: boardName(board) }, boardName(board)),
    h("div", { class: "board-sub" }, plural(members(board).length, "member")),
    h("span", { class: "spacer" }));
  if (ui.tab === "Notes") {
    const input = h("input", { class: "field", type: "search", placeholder: "Search", "aria-label": "Search notes",
      value: ui.query, "data-keep": "notes-search", autocomplete: "off" });
    input.addEventListener("input", () => {
      ui.query = input.value;
      render();
    });
    const newNote = h("button", { class: "btn new-btn", type: "button" }, "New Note");
    newNote.addEventListener("click", () => openNoteEditor(board, null));
    head.append(h("div", { class: "search" }, icon(ICONS.search), input), newNote);
  }

  const content = renderTabs[ui.tab]({
    board, boards, ui, now: now(), shown, allNotes, render,
    editNote: (note) => openNoteEditor(board, note),
    deleteNote: (note) => confirm("Delete this note for everyone on the board?", "Delete", async () => {
      await boards.deleteNote(board.id, note.id);
    }),
    editPlayer: (note) => openPlayerEditor(board, note),
    deletePlayer: (note) => confirm("Delete this player note for everyone on the board?", "Delete", async () => {
      await boards.deleteNote(board.id, note.id);
    }),
    selectTab: (tab, state) => {
      ui.tab = tab;
      Object.assign(ui.tabState, state);
      render();
    },
  });

  const right = ui.tab === "Notes" ? count(allNotes.length, shown.length) : "";
  const statusLine = h("div", { class: `status${status.dim ? " dim" : ""}`, role: "status" },
    dot(status), h("span", { class: "label" }, status.label), h("span", { class: "detail" }, status.detail),
    h("span", { class: "spacer" }), right);

  const tabs = h("div", { class: "tabs", role: "tablist" }, TABS.map((name) => {
    const tab = h("button", { class: "tab", role: "tab", type: "button", "aria-selected": String(ui.tab === name) }, name);
    tab.addEventListener("click", () => {
      ui.tab = name;
      boards.setSetting("tab", name);
      render();
    });
    return tab;
  }));

  const toggle = h("button", { class: "title-button title-left boards-toggle", type: "button", "aria-label": "Boards" }, icon(ICONS.menu));
  toggle.addEventListener("click", () => {
    ui.drawer = !ui.drawer;
    render();
  });
  const settings = h("button", { class: "title-button title-right", type: "button", "aria-label": "Settings", title: `You post as ${boards.me}` }, icon(ICONS.user));
  settings.addEventListener("click", settingsDialog);
  const shade = h("div", { class: "drawer-shade", onclick: () => { ui.drawer = false; render(); } });

  return h("div", { class: `window frame${ui.drawer ? " drawer-open" : ""}` },
    h("div", { class: "portrait" }, icon(ICONS.note)),
    h("div", { class: "titlebar" }, toggle, "Corkboard", settings),
    head,
    h("div", { class: "window-body" }, boardList(board), shade, h("div", { class: "content inset" }, content)),
    statusLine,
    tabs);
}

// Sync scheduling ---------------------------------------------------------------------

function canSync(board) {
  const retry = board.sync.retryAfter;
  const last = lastSync.get(board.id) || 0;
  return !(retry && Date.now() - last < retry * 1000);
}

async function syncNow(id) {
  const board = boards.get(id);
  if (!board || !canSync(board)) return;
  lastSync.set(id, Date.now());
  await boards.sync(id);
}

function schedulePush(id) {
  clearTimeout(pushTimers.get(id));
  pushTimers.set(id, setTimeout(() => syncNow(id), PUSH_DELAY));
}

function tick() {
  if (document.visibilityState !== "visible") return;
  const current = boards.current;
  for (const board of boards.list()) {
    // A refused secret stays refused until a new invite: polling would only
    // spend the server's registration limit (§7.3).
    if (board.sync.state === "refused") continue;
    const every = board === current ? POLL_CURRENT : POLL_OTHERS;
    if (Date.now() - (lastSync.get(board.id) || 0) >= every * 1000) syncNow(board.id);
  }
  // Ages in the status line and on cards move on even when nothing syncs.
  const minute = Math.floor(Date.now() / 60000);
  if (minute !== ui.minute && !selecting()) {
    ui.minute = minute;
    render();
  }
}

// Whether the reader is selecting text on the board, which a re-render
// would clear.
function selecting() {
  const selection = window.getSelection();
  return Boolean(selection && !selection.isCollapsed && root.contains(selection.anchorNode));
}

// Start --------------------------------------------------------------------------------

async function start() {
  root = document.getElementById("app");
  const storage = await openStorage();
  boards = await new Boards({ storage, api: new Api() }).load();
  if (TABS.includes(boards.settings.tab)) ui.tab = boards.settings.tab;
  boards.onChange((change) => {
    if (change.local && change.board) schedulePush(change.board);
    // Sync progress alone waits while text is selected; data changes don't.
    if (change.kind !== "sync" || !selecting()) render();
  });
  render();
  for (const board of boards.list()) syncNow(board.id);
  setInterval(tick, 5000);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible" && boards.current) syncNow(boards.current.id);
  });
  window.addEventListener("online", () => boards.current && syncNow(boards.current.id));
  window.addEventListener("beforeinstallprompt", (event) => {
    event.preventDefault();
    ui.installPrompt = event;
  });
  window.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && ui.drawer) {
      ui.drawer = false;
      render();
    }
  });
  if ("serviceWorker" in navigator && window.isSecureContext) {
    navigator.serviceWorker.register("sw.js").catch(() => {});
  }
}

start().catch((err) => {
  closeAll();
  popup({ message: `Corkboard couldn't start: ${err.message}`, buttons: [{ label: "Reload", onClick: () => location.reload() }] });
});
