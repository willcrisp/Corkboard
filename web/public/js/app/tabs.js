// The six window tabs, as in game (docs/ui-style.md "Phase 2 build notes"):
// Notes, Members, Gear, Professions, Quests and Players. Each takes the
// window's context and returns the inset's contents.

import { checkbox, h, icon, ICONS, searchBox, tick } from "./dom.js";
import { localLink, renderText } from "./links.js";
import { compute as computeDigest } from "../core/digest.js";
import {
  ARMOUR, ARMOUR_NAMES, decodeQuests, gear, GEAR_SHOWN, members, playerEntries, questLogs, recipeLists, VERDICT_LABELS,
} from "../model/formats.js";
import { collectLinks, nameIndex, plain } from "../model/text.js";
import { age, byline, byName, digestLabel, matches, plural, shortAge, shortName, tag } from "../model/view.js";
import * as invite from "../core/invite.js";

function scroll(name, ...children) {
  return h("div", { class: "scroll", "data-scroll": name }, children);
}

function empty(title, text) {
  return h("div", { class: "empty" }, title ? h("span", { class: "heading" }, title) : null, text);
}

function pendingMark(ctx, note) {
  return note.id in ctx.board.pending.notes ? h("span", { class: "pending-mark", title: "Not synced yet" }, "●") : null;
}

// Notes ---------------------------------------------------------------------------------

function notesTab(ctx) {
  const { shown, allNotes, now } = ctx;
  if (!allNotes.length) {
    return scroll("notes", empty("No notes yet", h("div", {}, "Click New Note to add one. Notes written in game show up here after a member's companion syncs the board.")));
  }
  if (!shown.length) return scroll("notes", empty(null, "No notes match your search."));
  const cards = shown.map((note) => {
    const t = tag(note.color);
    const edit = h("button", { class: "icon-btn", type: "button", "aria-label": "Edit note", title: "Edit" }, icon(ICONS.edit));
    const del = h("button", { class: "icon-btn", type: "button", "aria-label": "Delete note", title: "Delete" }, icon(ICONS.trash));
    edit.addEventListener("click", () => ctx.editNote(note));
    del.addEventListener("click", () => ctx.deleteNote(note));
    const card = h("article", { class: "card", "data-note": note.id },
      h("div", { class: "card-head" },
        h("span", { class: "swatch", style: { background: t.color }, title: t.name }),
        h("span", { class: "who", title: note.editor === note.author ? note.author : `${note.author}, edited by ${note.editor}` }, byline(note)),
        pendingMark(ctx, note),
        h("span", { class: "spacer" }),
        h("span", { class: "age", title: new Date(note.rev * 1000).toLocaleString() }, shortAge(now - note.rev)),
        h("span", { class: "actions" }, edit, del)),
      h("div", { class: "note-text" }, renderText(note.text)));
    card.addEventListener("dblclick", (event) => {
      if (!event.target.closest("a, button")) ctx.editNote(note);
    });
    return card;
  });
  return scroll("notes", h("div", { class: "grid" }, cards));
}

// Members --------------------------------------------------------------------------------

function membersTab(ctx) {
  const { board, now } = ctx;
  const code = invite.encode(board);
  const field = h("input", { class: "field invite-box", readonly: true, value: code, "aria-label": "Invite" });
  field.addEventListener("focus", () => field.select());
  const copy = h("button", { class: "btn", type: "button" }, "Copy");
  const hint = h("div", { class: "grey" }, "Anyone with this string can read and edit the board.");
  copy.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(code);
      hint.textContent = "Copied. Anyone with this string can read and edit the board.";
    } catch {
      field.focus();
      hint.textContent = "Selected. Press Ctrl+C to copy. Anyone with this string can read and edit the board.";
    }
  });

  // "Last active": the newest record each member wrote, since the web app
  // never hears the game's HELLOs.
  const active = new Map();
  for (const note of Object.values(board.notes)) {
    if (note.rev > (active.get(note.editor) || 0)) active.set(note.editor, note.rev);
  }
  const roster = members(board);
  const rows = roster.map((m) => {
    const at = active.get(m.name);
    const row = h("div", { class: "table-row", role: "row" },
      h("div", { class: "col-name", title: m.name, style: { color: "#ffffff" } }, shortName(m.name)),
      h("div", { class: "col-role grey" }, m.role === "owner" ? "Owner" : "Member"),
      h("div", { class: "col-rest grey" }, at ? age(now - at) : "-"));
    row.style.cursor = "pointer";
    row.title = "Show their quest log";
    row.addEventListener("click", () => ctx.selectTab("Quests", { questMember: m.name }));
    return row;
  });
  const sums = computeDigest(board.notes);
  const d = digestLabel(sums.count, board.clock, sums.digest);
  return scroll("members", h("div", { class: "section" },
    h("div", { class: "heading" }, "Invite"),
    h("div", { class: "copy-row" }, field, copy),
    hint,
    h("div", { class: "grey" }, `You post as ${ctx.boards.me}. Your notes reach players in game once a member's companion syncs this board and they /reload.`),
    h("div", { class: "rule" }),
    h("div", { class: "heading" }, "Members"),
    roster.length
      ? h("div", { class: "table", role: "table" },
        h("div", { class: "table-head", role: "row" },
          h("div", { class: "col-name" }, "Name"), h("div", { class: "col-role" }, "Role"), h("div", { class: "col-rest" }, "Last Active")),
        h("div", { class: "striped" }, rows))
      : h("div", { class: "grey" }, board.sync.at ? "Nobody has joined in game yet." : "Members appear after the first sync."),
    h("div", { class: "rule" }),
    h("div", { class: "grey small", title: "Count, clock and digest, as /cork debug shows them" }, `Board digest ${d}`)));
}

// Gear ------------------------------------------------------------------------------------

function gearTab(ctx) {
  const { board, now } = ctx;
  const entries = gear(board).slice(0, GEAR_SHOWN);
  const rows = entries.map((entry) => h("div", { class: "list-row" },
    h("div", { class: "main" }, h("span", { style: { color: "#ffffff" }, title: entry.author }, shortName(entry.author)),
      " equipped ", renderText(entry.text)),
    h("div", { class: "side" }, shortAge(now - entry.created))));
  return scroll("gear", h("div", { class: "section" },
    h("div", { class: "grey" }, "New rare and epic gear members equip, posted from the game."),
    rows.length ? h("div", { class: "striped" }, rows) : empty(null, "No gear posted yet.")));
}

// Professions -------------------------------------------------------------------------------

const RECIPES_SHOWN = 200;

function filtering(filter) {
  return filter.min !== null || filter.max !== null || Object.keys(filter.armour).length > 0;
}

// Whether a recipe's details pass the level and armour filter, as Recipes.passes in game.
function passes(detail, filter) {
  if (!filtering(filter)) return true;
  detail = detail || {};
  if ((filter.min !== null || filter.max !== null) && detail.level === undefined) return false;
  if ((filter.min !== null && detail.level < filter.min) || (filter.max !== null && detail.level > filter.max)) return false;
  if (Object.keys(filter.armour).length && !(detail.armour && filter.armour[detail.armour])) return false;
  return true;
}

// "Level 25 · Leather", or less.
function recipeInfo(detail) {
  if (!detail) return "";
  return [detail.level !== undefined ? `Level ${detail.level}` : null, ARMOUR_NAMES[detail.armour]]
    .filter(Boolean).join(" · ");
}

function professionsTab(ctx) {
  const { board, ui } = ctx;
  const query = ui.tabState.recipes || "";
  const state = ui.tabState.recipeFilter || (ui.tabState.recipeFilter = { min: "", max: "", armour: {} });
  const filter = {
    min: state.min === "" ? null : Number(state.min),
    max: state.max === "" ? null : Number(state.max),
    armour: state.armour,
  };
  const lists = recipeLists(board);
  const names = nameIndex(collectLinks(Object.values(board.notes).filter((n) => !n.deleted).map((n) => n.text)));
  const nameOf = (id) => names.get(`spell:${id}`) || `Recipe ${id}`;
  const search = searchBox(query, "Search recipes", (value) => {
    ui.tabState.recipes = value;
    ctx.render();
  });
  search.querySelector("input").dataset.keep = "recipes-search";
  const levelBox = (key, label) => {
    const input = h("input", { class: "field level-box", type: "text", inputmode: "numeric", maxlength: "3",
      "aria-label": label, value: state[key], autocomplete: "off", "data-keep": `recipes-${key}` });
    input.addEventListener("input", () => {
      state[key] = input.value.replace(/\D/g, "").replace(/^0+/, "");
      ctx.render();
    });
    return input;
  };
  const filters = h("div", { class: "row-line wrap recipe-filters" },
    h("span", { class: "heading" }, "Level"), levelBox("min", "Lowest level"), "–", levelBox("max", "Highest level"),
    ARMOUR.map((armour) => checkbox(ARMOUR_NAMES[armour], !!state.armour[armour], (on) => {
      if (on) state.armour[armour] = true;
      else delete state.armour[armour];
      ctx.render();
    })));
  let body;
  if (!lists.length) {
    body = empty(null, "Nobody shares their recipes on this board yet. Members share them from the Professions tab in game.");
  } else if (!/\S/.test(query) && !filtering(filter)) {
    // A click on a profession opens or closes the recipes it holds.
    const open = ui.tabState.openRecipes || (ui.tabState.openRecipes = {});
    body = h("div", { class: "striped" }, lists.map((l) => {
      const p = l.profession;
      const key = `${l.author}\n${p.id}`;
      const row = h("button", { class: "list-row profession-row", type: "button", "aria-expanded": String(!!open[key]) },
        h("span", { class: "toggle", "aria-hidden": "true" }, open[key] ? "\u2212" : "+"),
        h("div", { class: "main" }, h("span", { style: { color: "#ffffff" } }, p.name),
          h("span", { class: "grey" }, ` ${p.skill}/${p.max} · ${plural(p.learned, "recipe")}`)),
        h("div", { class: "side", title: l.author }, shortName(l.author)));
      row.addEventListener("click", () => {
        if (open[key]) delete open[key];
        else open[key] = true;
        ctx.render();
      });
      if (!open[key]) return row;
      const recipes = p.recipes.map((id) => ({ id, name: nameOf(id), detail: p.details?.[id] }))
        .sort((a, b) => a.name.localeCompare(b.name));
      return [row, recipes.length
        ? recipes.map((r) => h("div", { class: "list-row recipe-row" },
          h("div", { class: "main" }, localLink("enchant", r.id, r.name, "#ffd000")),
          h("div", { class: "side info" }, recipeInfo(r.detail))))
        : h("div", { class: "list-row recipe-row grey" }, "No recipes learned.")];
    }));
  } else {
    const found = new Map();
    for (const l of lists) {
      for (const id of l.profession.recipes) {
        const name = nameOf(id);
        const detail = l.profession.details?.[id];
        const row = found.get(id) || { id, name, profession: l.profession.name, who: [], detail };
        row.detail = row.detail || detail;
        row.who.push(l.author);
        found.set(id, row);
      }
    }
    const matched = [...found.values()]
      .filter((r) => passes(r.detail, filter) && matches(`${r.name}\n${r.profession}\n${r.who.join("\n")}`, query));
    const rows = matched.sort((a, b) => a.name.localeCompare(b.name)).slice(0, RECIPES_SHOWN);
    body = rows.length
      ? h("div", { class: "striped" }, rows.map((r) => h("div", { class: "list-row" },
        h("div", { class: "main" }, localLink("enchant", r.id, r.name, "#ffd000")),
        h("div", { class: "side info" }, recipeInfo(r.detail)),
        h("div", { class: "side" }, r.who.map(shortName).sort().join(", ")))))
      : empty(null, filtering(filter) ? "No recipes match your search and filters." : "No recipes match.");
    if (matched.length > RECIPES_SHOWN) body = [h("div", { class: "grey small" }, `Showing ${RECIPES_SHOWN} of ${matched.length}.`), body];
  }
  return scroll("professions", h("div", { class: "section" },
    h("div", { class: "row-line wrap" }, h("div", { class: "grey small spacer" }, "Click a profession to see its recipes. Recipe names come from links seen on this board; the rest show by id."), search),
    filters,
    body));
}

// Quests ------------------------------------------------------------------------------------

function questsTab(ctx) {
  const { board, ui, now } = ctx;
  const logs = questLogs(board);
  const names = nameIndex(collectLinks(Object.values(board.notes).filter((n) => !n.deleted).map((n) => n.text)));
  const authors = [...logs.keys()].sort(byName);
  if (!authors.length) {
    return scroll("quests", empty(null, "Nobody shares a quest log on this board yet. Members who tick the box on the Quests tab in game show up here."));
  }
  let chosen = ui.tabState.questMember;
  if (!chosen || !logs.has(chosen) && !members(board).some((m) => m.name === chosen)) chosen = authors[0];
  const list = h("div", { class: "members-col" }, authors.map((name) => {
    const quests = decodeQuests(logs.get(name).text);
    const b = h("button", { class: "board-item", type: "button", "aria-current": String(name === chosen) },
      h("span", { class: "name", title: name }, shortName(name)),
      h("span", { class: "detail" }, plural(quests.length, "quest")));
    b.addEventListener("click", () => {
      ui.tabState.questMember = name;
      ctx.render();
    });
    return b;
  }));
  const log = logs.get(chosen);
  let detail;
  if (!log) {
    detail = [h("div", { class: "heading", style: { fontSize: "15px" } }, shortName(chosen)),
      empty(null, `${shortName(chosen)} doesn't share a quest log on this board.`)];
  } else {
    const quests = decodeQuests(log.text).map((q) => ({ ...q, title: names.get(`quest:${q.id}`) || `Quest #${q.id}` }))
      .sort((a, b) => a.level - b.level || a.title.localeCompare(b.title));
    detail = [
      h("div", { class: "heading", style: { fontSize: "15px" } }, `${shortName(chosen)} · ${plural(quests.length, "quest")}`),
      h("div", { class: "grey small" }, `as of ${age(Math.max(0, now - log.rev))}`),
      quests.length
        ? h("div", { class: "striped" }, quests.map((q) => h("div", { class: "list-row" },
          h("div", { class: "main" }, localLink("quest", q.id, q.title, "#ffff00")),
          h("div", { class: "side" }, String(q.level)))))
        : empty(null, "No quests."),
    ];
  }
  return scroll("quests", h("div", { class: "split" }, list, h("div", { class: "detail-col" }, detail)));
}

// Players -------------------------------------------------------------------------------------

function playersTab(ctx) {
  const { board, ui, now } = ctx;
  const show = ui.tabState.show || { avoid: true, good: true };
  ui.tabState.show = show;
  const query = ui.tabState.players || "";
  const entries = playerEntries(board);
  const rows = entries.filter((e) => show[e.verdict] && matches(
    [e.name, plain(e.reason), VERDICT_LABELS[e.verdict], e.note.author, e.note.editor].join("\n"), query));
  const add = h("button", { class: "btn", type: "button" }, "Add Player");
  add.addEventListener("click", () => ctx.editPlayer(null));
  const search = searchBox(query, "Search", (value) => {
    ui.tabState.players = value;
    ctx.render();
  }, "Search players");
  search.querySelector("input").dataset.keep = "players-search";
  const avoid = entries.filter((e) => e.verdict === "avoid").length;
  const total = `${avoid} to avoid · ${plural(entries.length - avoid, "good player")}`;
  const list = rows.map((e) => {
    const edit = h("button", { class: "icon-btn", type: "button", "aria-label": `Edit ${e.name}`, title: "Edit" }, icon(ICONS.edit));
    const del = h("button", { class: "icon-btn", type: "button", "aria-label": `Delete ${e.name}`, title: "Delete" }, icon(ICONS.trash));
    edit.addEventListener("click", () => ctx.editPlayer(e.note));
    del.addEventListener("click", () => ctx.deletePlayer(e.note));
    return h("div", { class: "player-row" },
      h("div", { class: "top" }, tick(e.verdict),
        h("span", { class: "name" }, e.name),
        h("span", { class: `verdict ${e.verdict}` }, VERDICT_LABELS[e.verdict]),
        pendingMark(ctx, e.note),
        h("span", { class: "spacer" }),
        h("span", { class: "meta grey small" }, `${byline(e.note)} · ${shortAge(now - e.note.rev)}`),
        h("span", { class: "actions" }, edit, del)),
      e.reason ? h("div", { class: "note-text reason" }, renderText(e.reason)) : null);
  });
  return h("div", { style: { display: "flex", flexDirection: "column", minHeight: 0, flexGrow: 1 } },
    scroll("players", h("div", { class: "section" },
      h("div", { class: "row-line wrap" },
        checkbox("Avoid", show.avoid, (v) => { show.avoid = v; ctx.render(); }),
        checkbox("Good players", show.good, (v) => { show.good = v; ctx.render(); }),
        h("span", { class: "spacer" }), search, add),
      h("div", { class: "grey small" }, "Players this board's members have noted, to avoid or to group with again. Only members see these. In game they show on the player's tooltip, and an avoided player joining your group prints a warning."),
      list.length ? h("div", { class: "striped" }, list)
        : empty(null, entries.length ? "No player notes match." : "No player notes yet. Click Add Player to note someone."))),
    h("div", { class: "grey small", style: { padding: "4px 10px 6px" } },
      rows.length !== entries.length ? `${rows.length} shown · ${total}` : total));
}

export const renderTabs = {
  Notes: notesTab,
  Members: membersTab,
  Gear: gearTab,
  Professions: professionsTab,
  Quests: questsTab,
  Players: playersTab,
};
