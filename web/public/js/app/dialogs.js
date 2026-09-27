// Popups (StaticPopupDialogs) and the two editors (UI/Editor.lua,
// UI/PlayerEditor.lua), rebuilt for the browser.

import { h, icon, ICONS } from "./dom.js";
import * as sanitise from "../core/sanitise.js";
import { byteLen } from "../core/util.js";
import { collectLinks, toEditable, toText } from "../model/text.js";
import { encodePlayer, decodePlayer } from "../model/formats.js";
import { counter, editorHeader, explain, tag, TAGS } from "../model/view.js";

let open = [];

function mount(el, { onClose, dismissable = true } = {}) {
  const overlay = h("div", { class: "overlay" }, el);
  const close = () => {
    overlay.remove();
    document.removeEventListener("keydown", onKey);
    open = open.filter((c) => c !== close);
    onClose?.();
  };
  const onKey = (event) => {
    if (event.key === "Escape" && open[open.length - 1] === close) {
      event.preventDefault();
      close();
    }
  };
  if (dismissable) {
    overlay.addEventListener("mousedown", (event) => { if (event.target === overlay) close(); });
  }
  document.addEventListener("keydown", onKey);
  document.body.append(overlay);
  open.push(close);
  return close;
}

export function closeAll() {
  for (const close of [...open].reverse()) close();
}

// A StaticPopup: a message, optional body, and buttons. Enter presses the
// first button unless focus is in a multi-line field.
export function popup({ message, body = [], buttons, onClose }) {
  const buttonEls = buttons.map((b) => h("button", { class: "btn", type: "button", disabled: b.disabled }, b.label));
  const el = h("form", { class: "popup frame", role: "dialog", "aria-modal": "true", "aria-label": message },
    h("div", { class: "message" }, message), body, h("div", { class: "buttons" }, buttonEls));
  const close = mount(el, { onClose });
  buttons.forEach((b, i) => buttonEls[i].addEventListener("click", async (event) => {
    event.preventDefault();
    if ((await b.onClick?.()) !== false) close();
  }));
  el.addEventListener("submit", (event) => {
    event.preventDefault();
    if (!buttonEls[0].disabled) buttonEls[0].click();
  });
  requestAnimationFrame(() => (el.querySelector("input, textarea") || buttonEls[0]).focus());
  return { close, el, buttons: buttonEls };
}

export function confirm(message, yes, onYes) {
  return popup({ message, buttons: [{ label: yes, onClick: onYes }, { label: "Cancel" }] });
}

export function notice(message) {
  return popup({ message, buttons: [{ label: "Okay" }] });
}

// A popup with one text field. submit(value) returns a reason string to show
// (and keep the popup open) or nothing to close it.
export function ask({ message, value = "", placeholder = "", note, label, submit, okay = "Okay", cancel = true }) {
  const input = h("input", { class: "field", value, placeholder, "aria-label": label || message, autocomplete: "off",
    spellcheck: "false" });
  const error = h("div", { class: "error", role: "alert" });
  const buttons = [{
    label: okay,
    onClick: async () => {
      const reason = await submit(input.value);
      if (reason) {
        error.textContent = explain(reason);
        return false;
      }
      return true;
    },
  }];
  if (cancel) buttons.push({ label: "Cancel" });
  const p = popup({ message, body: [input, note ? h("div", { class: "note" }, note) : null, error], buttons });
  requestAnimationFrame(() => input.select());
  return p;
}

function dialogFrame(title, onClose) {
  const closeBtn = h("button", { class: "title-button title-right", type: "button", "aria-label": "Close" }, icon(ICONS.close));
  const body = h("div", { class: "dialog-body" });
  const el = h("div", { class: "dialog frame", role: "dialog", "aria-modal": "true", "aria-label": title },
    h("div", { class: "titlebar" }, title, closeBtn), body);
  const close = mount(el, { onClose, dismissable: false });
  closeBtn.addEventListener("click", close);
  return { el, body, close };
}

// The link picker: the web app's stand-in for shift-clicking. It lists every
// link on the board so one can go into a note.
function linkPicker(board, onPick) {
  const links = collectLinks(Object.values(board.notes || {}).filter((n) => !n.deleted).map((n) => n.text));
  const search = h("input", { class: "field", placeholder: "Search links on this board", "aria-label": "Search links",
    autocomplete: "off" });
  const list = h("div", { class: "picker-list inset" });
  const render = () => {
    list.replaceChildren();
    const q = search.value.toLowerCase();
    const shown = links.filter((l) => l.label.toLowerCase().includes(q)).slice(0, 100);
    if (!shown.length) list.append(h("div", { class: "empty small" }, links.length ? "No links match." : "No links on this board yet. Links come from notes written in game."));
    for (const l of shown) {
      list.append(h("button", { type: "button", style: { color: l.color || "#ffffff" }, onclick: () => onPick(l) }, l.label));
    }
  };
  search.addEventListener("input", render);
  render();
  const el = h("div", { class: "picker" }, search, list);
  return { el, focus: () => search.focus() };
}

// The note editor: a text box that shows links as [Name], a byte counter, a
// tag picker, and Delete / Cancel / Save. Save stays disabled while the text
// would fail the sanitiser, and says why (§9).
export function noteEditor({ board, note, now, onSave, onDelete }) {
  const title = note ? "Edit Note" : "New Note";
  const { body, close } = dialogFrame(title);
  const start = note ? toEditable(note.text) : { text: "", links: new Map(), strays: 0 };
  const links = new Map(start.links);
  let color = note ? note.color : 1;

  const textarea = h("textarea", { class: "textarea", "aria-label": "Note", spellcheck: "true" });
  textarea.value = start.text;
  const count = h("span");
  const message = h("div", { class: "warn small", role: "alert" });
  const tagName = h("span", { class: "grey small" });
  const swatchEls = TAGS.map((t, i) => {
    const b = h("button", { class: "swatch-btn", type: "button", "aria-label": t.name, title: t.name,
      style: { background: t.color } });
    b.addEventListener("click", () => { color = i + 1; paint(); });
    return b;
  });
  const save = h("button", { class: "btn", type: "button" }, "Save");
  const del = note ? h("button", { class: "btn", type: "button" }, "Delete") : null;
  const cancel = h("button", { class: "btn", type: "button" }, "Cancel");
  const linkBtn = h("button", { class: "btn small", type: "button" }, "Link…");
  const pickerHolder = h("div");

  function paint() {
    swatchEls.forEach((b, i) => b.setAttribute("aria-pressed", String(i + 1 === color)));
    tagName.textContent = tag(color).name;
  }

  function currentText() {
    return toText(textarea.value, links);
  }

  function validate() {
    const text = currentText();
    const c = counter(byteLen(text));
    count.textContent = c.label;
    count.className = c.over ? "over" : "";
    let ok = /[^ \t\n\v\f\r]/.test(text);
    let why = ok ? null : "empty";
    if (ok) {
      const [valid, reason] = sanitise.text(text);
      ok = valid;
      why = reason;
    }
    message.textContent = ok || textarea.value === "" ? "" : explain(why);
    save.disabled = !ok;
    return ok;
  }

  linkBtn.addEventListener("click", () => {
    if (pickerHolder.firstChild) {
      pickerHolder.replaceChildren();
      return;
    }
    const picker = linkPicker(board, (l) => {
      links.set(l.token, l.raw);
      const { selectionStart: a, selectionEnd: b, value } = textarea;
      textarea.value = value.slice(0, a) + l.token + value.slice(b);
      textarea.selectionStart = textarea.selectionEnd = a + l.token.length;
      pickerHolder.replaceChildren();
      textarea.focus();
      validate();
    });
    pickerHolder.replaceChildren(picker.el);
    picker.focus();
  });

  save.addEventListener("click", async () => {
    if (!validate()) return;
    const reason = await onSave(currentText(), color);
    if (reason) message.textContent = explain(reason);
    else close();
  });
  cancel.addEventListener("click", close);
  del?.addEventListener("click", () => {
    confirm("Delete this note for everyone on the board?", "Delete", async () => {
      const reason = await onDelete();
      if (!reason) close();
    });
  });
  textarea.addEventListener("input", validate);
  textarea.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) save.click();
  });

  body.append(
    h("div", { class: "grey small" }, editorHeader(board.meta ? board.meta.name : board.id, note, now)),
    h("div", { class: "field-group" },
      h("div", { class: "row-line" }, h("span", { class: "heading" }, "Note"), h("span", { class: "spacer" }), linkBtn),
      textarea,
      h("div", { class: "hint-row" },
        h("span", {}, start.strays ? "Colour codes outside links are removed when you save." : "Use Link… to add an item, quest or spell from this board"),
        count)),
    pickerHolder,
    h("div", { class: "row-line" }, h("span", { class: "heading" }, "Tag"), h("div", { class: "swatches" }, swatchEls), tagName),
    message,
    h("div", { class: "dialog-foot" }, del, h("span", { class: "spacer" }), cancel, save),
  );
  paint();
  validate();
  requestAnimationFrame(() => {
    textarea.focus();
    textarea.selectionStart = textarea.selectionEnd = textarea.value.length;
  });
  return close;
}

// The player-note editor: Character, Avoid or Good player, and Why (§9.4).
export function playerEditor({ board, note, now, onSave, onDelete }) {
  const entry = note ? decodePlayer(note.text) : null;
  const { body, close } = dialogFrame(note ? "Edit Player Note" : "Add Player");
  const start = entry ? toEditable(entry.reason) : { text: "", links: new Map(), strays: 0 };
  const links = new Map(start.links);
  let verdict = entry ? entry.verdict : "avoid";

  const nameInput = h("input", { class: "field", "aria-label": "Character", placeholder: "Name, or Name-Realm",
    value: entry ? entry.name : "", autocomplete: "off", spellcheck: "false" });
  const why = h("textarea", { class: "textarea", "aria-label": "Why", style: { minHeight: "110px" } });
  why.value = start.text;
  const count = h("span");
  const message = h("div", { class: "warn small", role: "alert" });
  const save = h("button", { class: "btn", type: "button" }, "Save");
  const del = note ? h("button", { class: "btn", type: "button" }, "Delete") : null;
  const cancel = h("button", { class: "btn", type: "button" }, "Cancel");
  const radios = {};
  for (const [key, label] of [["avoid", "Avoid"], ["good", "Good player"]]) {
    radios[key] = h("button", { class: "check", type: "button", role: "radio" }, h("span", { class: "box" }, icon(ICONS.check)), h("span", {}, label));
    radios[key].addEventListener("click", () => { verdict = key; paint(); validate(); });
  }

  function paint() {
    for (const key of Object.keys(radios)) radios[key].setAttribute("aria-checked", String(key === verdict));
  }

  function encoded() {
    return encodePlayer(nameInput.value, verdict, toText(why.value, links));
  }

  function validate() {
    const [text, reason] = encoded();
    const size = text ? byteLen(text) : byteLen(`P1;${verdict};${nameInput.value}\n${toText(why.value, links)}`);
    const c = counter(size);
    count.textContent = c.label;
    count.className = c.over ? "over" : "";
    const ok = Boolean(text);
    message.textContent = ok || !/\S/.test(nameInput.value) ? "" : explain(reason);
    save.disabled = !ok;
    return ok;
  }

  save.addEventListener("click", async () => {
    if (!validate()) return;
    const reason = await onSave(nameInput.value, verdict, toText(why.value, links));
    if (reason) message.textContent = explain(reason);
    else close();
  });
  cancel.addEventListener("click", close);
  del?.addEventListener("click", () => {
    confirm("Delete this player note for everyone on the board?", "Delete", async () => {
      const reason = await onDelete();
      if (!reason) close();
    });
  });
  nameInput.addEventListener("input", validate);
  why.addEventListener("input", validate);

  body.append(
    h("div", { class: "grey small" }, editorHeader(board.meta ? board.meta.name : board.id, note, now)),
    h("div", { class: "field-group" }, h("span", { class: "heading" }, "Character"), nameInput),
    h("div", { class: "row-line", role: "radiogroup", "aria-label": "Verdict", style: { gap: "24px" } }, radios.avoid, radios.good),
    h("div", { class: "field-group" }, h("span", { class: "heading" }, "Why"), why,
      h("div", { class: "hint-row" }, h("span", {}, "Only members of this board see this."), count)),
    message,
    h("div", { class: "dialog-foot" }, del, h("span", { class: "spacer" }), cancel, save),
  );
  paint();
  validate();
  requestAnimationFrame(() => (entry ? why : nameInput).focus());
  return close;
}
