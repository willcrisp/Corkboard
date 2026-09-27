// Note text on screen (UI/Links.lua's job in game): plain runs as text,
// links in their colour with a GameTooltip-style box on hover or tap. The
// web app has no item data, so the tooltip shows what the link itself holds:
// its name, what kind of link it is, and its id.

import { h } from "./dom.js";
import { LINK_LABELS, linkId, parse } from "../model/text.js";

let tip = null;
let pinned = null;

function hideTip() {
  tip?.remove();
  tip = null;
  pinned = null;
}

function place(el, anchor) {
  const r = anchor.getBoundingClientRect();
  const box = el.getBoundingClientRect();
  const left = Math.min(r.left, window.innerWidth - box.width - 8);
  let top = r.bottom + 6;
  if (top + box.height > window.innerHeight - 8) top = r.top - box.height - 6;
  el.style.left = `${Math.max(8, left)}px`;
  el.style.top = `${Math.max(8, top)}px`;
}

export function tooltip(anchor, lines) {
  hideTip();
  tip = h("div", { class: "tooltip", role: "tooltip" }, lines);
  document.body.append(tip);
  place(tip, anchor);
}

function linkTooltip(anchor, seg) {
  const id = linkId(seg);
  const kind = LINK_LABELS[seg.link] || seg.link;
  tooltip(anchor, [
    h("div", { class: "tt-title", style: { color: seg.color || "#ffffff" } }, seg.label.replace(/^\[(.*)\]$/, "$1")),
    h("div", { class: "tt-line" }, kind),
    id !== null ? h("div", { class: "tt-grey" }, `${kind} ID ${id}`) : null,
  ]);
}

function linkElement(seg) {
  const a = h("a", { class: "link", tabindex: "0", role: "button", style: { color: seg.color || "#ffffff" } }, seg.label);
  a.addEventListener("mouseenter", () => { if (!pinned) linkTooltip(a, seg); });
  a.addEventListener("mouseleave", () => { if (pinned !== a) hideTip(); });
  a.addEventListener("focus", () => linkTooltip(a, seg));
  a.addEventListener("blur", hideTip);
  a.addEventListener("click", (event) => {
    event.stopPropagation();
    if (pinned === a) {
      hideTip();
      return;
    }
    linkTooltip(a, seg);
    pinned = a;
  });
  return a;
}

// Sanitised note text as DOM nodes.
export function renderText(text) {
  return parse(text).map((seg) => {
    if (seg.type === "link") return linkElement(seg);
    return seg.color ? h("span", { style: { color: seg.color } }, seg.text) : document.createTextNode(seg.text);
  });
}

// A link built by the app (quests and recipes by id), shown like any other.
export function localLink(link, id, label, color) {
  return linkElement({ link, data: String(id), label: `[${label}]`, color });
}

document.addEventListener("click", () => { if (pinned) hideTip(); });
document.addEventListener("scroll", hideTip, true);
window.addEventListener("resize", hideTip);
