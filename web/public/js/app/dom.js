// A tiny DOM builder. Every piece of board text goes in as a text node, never
// as HTML, so nothing a member writes can run in the page.

export function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs || {})) {
    if (value === undefined || value === null || value === false) continue;
    if (key === "class") el.className = value;
    else if (key === "style" && typeof value === "object") Object.assign(el.style, value);
    else if (key.startsWith("on") && typeof value === "function") el.addEventListener(key.slice(2), value);
    else if (key === "value") el.value = value;
    else el.setAttribute(key, value === true ? "" : value);
  }
  append(el, children);
  return el;
}

export function append(el, children) {
  for (const child of children.flat(Infinity)) {
    if (child === undefined || child === null || child === false) continue;
    el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return el;
}

const SVG = "http://www.w3.org/2000/svg";

// An inline SVG icon from path data (24-unit viewBox).
export function icon(paths, cls) {
  const svg = document.createElementNS(SVG, "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("aria-hidden", "true");
  if (cls) svg.setAttribute("class", cls);
  for (const d of [].concat(paths)) {
    const path = document.createElementNS(SVG, "path");
    path.setAttribute("d", d);
    svg.append(path);
  }
  return svg;
}

export const ICONS = {
  note: ["M5 4h14v11l-5 5H5z", "M14 20v-5h5", "M8 9h8M8 12h6"],
  close: ["M6 6l12 12M18 6L6 18"],
  edit: ["M4 20h4L19 9l-4-4L4 16v4z"],
  trash: ["M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"],
  search: ["M11 4a7 7 0 1 0 0 14a7 7 0 1 0 0-14z", "M20 20l-3.5-3.5"],
  check: ["M5 12l5 5 9-10"],
  menu: ["M4 7h16M4 12h16M4 17h16"],
  user: ["M12 4a4 4 0 1 0 0 8a4 4 0 1 0 0-8z", "M4 21c0-4 3.6-6.5 8-6.5s8 2.5 8 6.5"],
  cross: ["M6 6l12 12M18 6L6 18"],
};

// The ready-check marks beside player notes and shared quests.
export function tick(kind) {
  return icon(kind === "avoid" ? ICONS.cross : ICONS.check, `tick ${kind}`);
}

export function checkbox(label, checked, onChange, attrs = {}) {
  const button = h("button", { class: "check", role: "checkbox", "aria-checked": String(Boolean(checked)), type: "button", ...attrs },
    h("span", { class: "box" }, icon(ICONS.check)), h("span", {}, label));
  button.addEventListener("click", () => {
    const next = button.getAttribute("aria-checked") !== "true";
    button.setAttribute("aria-checked", String(next));
    onChange(next);
  });
  return button;
}

export function searchBox(value, placeholder, onInput, label) {
  const input = h("input", { class: "field", type: "search", placeholder, "aria-label": label || placeholder,
    value, autocomplete: "off", spellcheck: "false" });
  input.addEventListener("input", () => onInput(input.value));
  return h("div", { class: "search" }, icon(ICONS.search), input);
}
