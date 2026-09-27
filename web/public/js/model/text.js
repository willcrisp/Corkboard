// Note text as the web app shows and edits it (docs/design.md §6, §7.4).
//
// Text on a board has already passed the sanitiser, so its only escapes are
// "||", colours ("|cAARRGGBB", "|cnNAME:", "|r") and links
// ("|H<type>:<data>|h<label>|h"). The game wraps each link in a colour:
// "|cff1eff00|Hitem:19019::|h[Thunderfury]|h|r". parse() splits text into
// plain runs and links, keeping each link's exact source so an edit can put
// it back byte for byte.
//
// The editor is a plain text box, so links show there as their label,
// "[Thunderfury]", and toText() turns every label it knows back into the
// original link. Pipes the user types become "||", the same escape the
// game's edit boxes write.

import * as sanitise from "../core/sanitise.js";

// Item quality colours for "|cnIQ<n>:" (ITEM_QUALITY_COLORS).
export const QUALITY = {
  IQ0: "#9d9d9d", IQ1: "#ffffff", IQ2: "#1eff00", IQ3: "#0070dd", IQ4: "#a335ee",
  IQ5: "#ff8000", IQ6: "#e6cc80", IQ7: "#00ccff", IQ8: "#00ccff",
};

export const LINK_LABELS = {
  item: "Item", quest: "Quest", spell: "Spell", achievement: "Achievement", currency: "Currency",
  mount: "Mount", battlepet: "Battle Pet", journal: "Encounter Journal", enchant: "Recipe", trade: "Profession",
};

const COLOUR = /\|c([0-9A-Fa-f]{8})/y;
const NAMED = /\|cn([0-9A-Za-z_]+):/y;
const LINK = /\|H([^:|]*):([^|]*)\|h([^|]*)\|h/y;

function sticky(re, s, pos) {
  re.lastIndex = pos;
  return re.exec(s);
}

function colourAt(s, pos) {
  let m = sticky(COLOUR, s, pos);
  if (m) return { css: `#${m[1].slice(2).toLowerCase()}`, end: COLOUR.lastIndex };
  m = sticky(NAMED, s, pos);
  if (m) return { css: QUALITY[m[1]] || null, end: NAMED.lastIndex };
  return null;
}

// Splits sanitised text into segments:
//   { type: "text", text, color }            plain text, pipes unescaped
//   { type: "link", link, data, label, color, raw }
// `color` is a CSS colour or null. A link's `raw` spans the colour code just
// before it and the "|r" just after it, when they're there. Colour codes
// that don't wrap a link are counted in `strays`.
export function parse(s) {
  const segments = [];
  const stack = [];
  let buffer = "";
  let strays = 0;
  let pos = 0;
  const colour = () => (stack.length ? stack[stack.length - 1] : null);
  const flush = () => {
    if (buffer) segments.push({ type: "text", text: buffer, color: colour() });
    buffer = "";
  };
  while (pos < s.length) {
    const p = s.indexOf("|", pos);
    if (p < 0) {
      buffer += s.slice(pos);
      break;
    }
    buffer += s.slice(pos, p);
    const c = s.charAt(p + 1);
    if (c === "|") {
      buffer += "|";
      pos = p + 2;
      continue;
    }
    if (c === "c") {
      const col = colourAt(s, p);
      if (!col) { // not reachable for sanitised text; keep it visible
        buffer += "|";
        pos = p + 1;
        continue;
      }
      const link = sticky(LINK, s, col.end);
      if (link) {
        let end = LINK.lastIndex;
        if (s.startsWith("|r", end)) end += 2;
        flush();
        segments.push({ type: "link", link: link[1], data: link[2], label: link[3], color: col.css,
          raw: s.slice(p, end) });
        pos = end;
        continue;
      }
      flush();
      stack.push(col.css);
      strays++;
      pos = col.end;
      continue;
    }
    if (c === "r") {
      flush();
      stack.pop();
      strays++;
      pos = p + 2;
      continue;
    }
    if (c === "H") {
      const link = sticky(LINK, s, p);
      if (link) {
        flush();
        segments.push({ type: "link", link: link[1], data: link[2], label: link[3], color: colour(),
          raw: s.slice(p, LINK.lastIndex) });
        pos = LINK.lastIndex;
        continue;
      }
    }
    buffer += "|";
    pos = p + 1;
  }
  flush();
  segments.strays = strays;
  return segments;
}

// Text as a reader sees it: links become their label and escapes go
// (View.plainText).
export function plain(s) {
  return parse(s).map((seg) => (seg.type === "link" ? seg.label : seg.text)).join("");
}

// The id in a link's data: "item:19019::" -> 19019.
export function linkId(seg) {
  const m = /^(\d+)/.exec(seg.data);
  return m ? Number(m[1]) : null;
}

// How a link shows in the editor: its label, in brackets if it has none.
export function token(seg) {
  const label = seg.label;
  return label.startsWith("[") && label.endsWith("]") ? label : `[${label}]`;
}

// Text for the editor: { text, links, strays }. `links` maps each token to
// the link's source; `strays` counts colour codes that aren't part of a link,
// which an edit drops.
export function toEditable(s) {
  const links = new Map();
  let text = "";
  const segments = parse(s);
  for (const seg of segments) {
    if (seg.type === "link") {
      const t = token(seg);
      if (!links.has(t)) links.set(t, seg.raw);
      text += t;
    } else {
      text += seg.text;
    }
  }
  return { text, links, strays: segments.strays };
}

// Editor text back to note text: pipes escaped, and every "[Label]" that
// names a known link (from the note itself or the link picker) turned back
// into that link. Line endings become "\n".
export function toText(editable, links) {
  const s = editable.replace(/\r\n?/g, "\n");
  let out = "";
  let pos = 0;
  const escape = (t) => t.replace(/\|/g, "||");
  while (pos < s.length) {
    const open = s.indexOf("[", pos);
    if (open < 0) break;
    // The longest known token starting here wins; labels can hold "]".
    let match = null;
    for (const t of links.keys()) {
      if (s.startsWith(t, open) && (!match || t.length > match.length)) match = t;
    }
    if (match) {
      out += escape(s.slice(pos, open)) + links.get(match);
      pos = open + match.length;
    } else {
      out += escape(s.slice(pos, open + 1));
      pos = open + 1;
    }
  }
  return out + escape(s.slice(pos));
}

// Every distinct link in a set of texts, for the link picker and the name
// index: [{ raw, token, label, link, data, color, id }], sorted by label.
export function collectLinks(texts) {
  const seen = new Map();
  for (const s of texts) {
    if (!s || !s.includes("|H")) continue;
    for (const seg of parse(s)) {
      if (seg.type !== "link" || seen.has(seg.raw)) continue;
      if (!sanitise.text(seg.raw)[0]) continue;
      seen.set(seg.raw, { raw: seg.raw, token: token(seg), label: seg.label, link: seg.link, data: seg.data,
        color: seg.color, id: linkId(seg) });
    }
  }
  return [...seen.values()].sort((a, b) => a.label.localeCompare(b.label) || (a.raw < b.raw ? -1 : 1));
}

// Names learned from links: "quest:123" -> "[Title]", so the Quests and
// Professions tabs can name ids the game would otherwise have to look up.
export function nameIndex(links) {
  const names = new Map();
  for (const l of links) {
    if (l.id === null) continue;
    const bare = l.label.replace(/^\[(.*)\]$/, "$1");
    if (l.link === "quest") names.set(`quest:${l.id}`, bare);
    else if (l.link === "enchant" || l.link === "spell") {
      if (!names.has(`spell:${l.id}`) || l.link === "enchant") names.set(`spell:${l.id}`, bare);
    }
  }
  return names;
}
