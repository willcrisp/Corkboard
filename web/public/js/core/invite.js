// Invite strings (docs/design.md §9, Core/Invite.lua, corkcore/invite.py):
// CORK1:<base64(boardId|secret|ownerName)>.

import * as sanitise from "./sanitise.js";
import { fromBytes, toBytes } from "./util.js";

export const PREFIX = "CORK1:";
const ID = /^[0-9a-z]{16}$/;
const SECRET = /^[0-9A-Za-z]{16,64}$/;
const VERSION = /^[Cc][Oo][Rr][Kk]([0-9]+):([\s\S]*)$/;
const BASE64 = /^[A-Za-z0-9+/]*$/;
const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

export function validId(id) {
  return typeof id === "string" && ID.test(id);
}

export function validSecret(secret) {
  return typeof secret === "string" && SECRET.test(secret);
}

function base64(bytes) {
  let out = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i];
    const b = bytes[i + 1];
    const c = bytes[i + 2];
    const n = (a << 16) | ((b ?? 0) << 8) | (c ?? 0);
    out += ALPHABET[n >> 18] + ALPHABET[(n >> 12) & 63]
      + (b === undefined ? "=" : ALPHABET[(n >> 6) & 63])
      + (c === undefined ? "=" : ALPHABET[n & 63]);
  }
  return out;
}

// Unpadded standard base64 (already checked against the alphabet) to bytes.
// Leftover bits are ignored, as Python's decoder does.
function unbase64(body) {
  const bytes = [];
  let bits = 0;
  let value = 0;
  for (const ch of body) {
    value = (value << 6) | ALPHABET.indexOf(ch);
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      bytes.push((value >> bits) & 0xff);
    }
  }
  return bytes;
}

export function encode(board) {
  return PREFIX + base64(toBytes(`${board.id}|${board.secret}|${board.owner}`));
}

// [{id, secret, owner}, null] or [null, reason].
export function decode(s) {
  if (typeof s !== "string") return [null, "invite"];
  // Lua's %s: space, \t, \n, \v, \f, \r.
  s = s.replace(/^[ \t\n\v\f\r]+|[ \t\n\v\f\r]+$/g, "");
  const m = VERSION.exec(s);
  if (!m) return [null, "invite"];
  if (m[1] !== "1") return [null, "invite_version"];
  const body = m[2].replace(/=+$/, "");
  if (body.length % 4 === 1 || !BASE64.test(body)) return [null, "invite_corrupt"];
  const text = fromBytes(unbase64(body));
  const first = text.indexOf("|");
  const second = first < 0 ? -1 : text.indexOf("|", first + 1);
  if (second < 0) return [null, "invite_corrupt"];
  const id = text.slice(0, first);
  const secret = text.slice(first + 1, second);
  const owner = text.slice(second + 1);
  if (!validId(id) || !validSecret(secret) || !sanitise.name(owner)) return [null, "invite_corrupt"];
  return [{ id, secret, owner }, null];
}
