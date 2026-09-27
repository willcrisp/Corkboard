// Byte-level helpers shared by the merge core (Core/Util.lua, corkcore/util.py).
//
// Lua holds strings as bytes and Python as code points; JavaScript holds
// UTF-16. Every rule here is defined on the UTF-8 bytes, so strings are
// compared, measured and hashed through toBytes. A lone surrogate
// U+DC80-U+DCFF stands for one invalid byte, as Python's "surrogateescape"
// does, so the shared vectors' input_hex cases round-trip exactly.

export const INT_MAX = 9007199254740991; // 2^53 - 1, the largest integer a Lua number holds exactly

export const FNV_OFFSET = 2166136261;
export const FNV_PRIME = 16777619;

// A string as the bytes Lua would hold.
export function toBytes(s) {
  const out = [];
  for (let i = 0; i < s.length; i++) {
    let c = s.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
      const d = s.charCodeAt(i + 1);
      if (d >= 0xdc00 && d <= 0xdfff) {
        c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00);
        i++;
        out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 0x3f), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
        continue;
      }
    }
    if (c < 0x80) {
      out.push(c);
    } else if (c < 0x800) {
      out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
    } else if (c >= 0xdc80 && c <= 0xdcff) {
      out.push(c - 0xdc00); // an escaped invalid byte
    } else if (c >= 0xd800 && c <= 0xdfff) {
      out.push(0xef, 0xbf, 0xbd); // any other lone surrogate: what an encoder would write
    } else {
      out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
    }
  }
  return out;
}

// Bytes to a string: strict UTF-8, with each byte of an invalid sequence
// kept as U+DC00 + byte (Python's bytes.decode("utf-8", "surrogateescape")).
export function fromBytes(bytes) {
  let out = "";
  let i = 0;
  const n = bytes.length;
  const escape = (b) => String.fromCharCode(0xdc00 + b);
  while (i < n) {
    const b = bytes[i];
    if (b < 0x80) {
      out += String.fromCharCode(b);
      i++;
      continue;
    }
    let need, cp, lo = 0x80, hi = 0xbf;
    if (b >= 0xc2 && b <= 0xdf) {
      need = 1; cp = b & 0x1f;
    } else if (b >= 0xe0 && b <= 0xef) {
      need = 2; cp = b & 0x0f;
      if (b === 0xe0) lo = 0xa0;
      if (b === 0xed) hi = 0x9f;
    } else if (b >= 0xf0 && b <= 0xf4) {
      need = 3; cp = b & 0x07;
      if (b === 0xf0) lo = 0x90;
      if (b === 0xf4) hi = 0x8f;
    } else {
      out += b < 0x80 ? String.fromCharCode(b) : escape(b);
      i++;
      continue;
    }
    let j = 1;
    for (; j <= need; j++) {
      const c = bytes[i + j];
      const min = j === 1 ? lo : 0x80;
      const max = j === 1 ? hi : 0xbf;
      if (c === undefined || c < min || c > max) break;
      cp = (cp << 6) | (c & 0x3f);
    }
    if (j <= need) {
      // Invalid: escape the lead byte and the continuation bytes that were
      // accepted, then carry on from the byte that broke the sequence.
      for (let k = 0; k < j; k++) out += escape(bytes[i + k]);
      i += j;
      continue;
    }
    out += String.fromCodePoint(cp);
    i += need + 1;
  }
  return out;
}

export function byteLen(s) {
  return toBytes(s).length;
}

// Strict UTF-8: a string with a lone surrogate came from invalid bytes.
export function isUtf8(s) {
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff) {
      const d = s.charCodeAt(i + 1);
      if (!(d >= 0xdc00 && d <= 0xdfff)) return false;
      i++;
    } else if (c >= 0xdc00 && c <= 0xdfff) {
      return false;
    }
  }
  return true;
}

function compareByteArrays(x, y) {
  const n = Math.min(x.length, y.length);
  for (let i = 0; i < n; i++) {
    if (x[i] !== y[i]) return x[i] < y[i] ? -1 : 1;
  }
  return x.length === y.length ? 0 : x.length < y.length ? -1 : 1;
}

// Three-way byte-wise compare, -1, 0 or 1, like Util.compare.
export function compare(a, b) {
  if (a === b) return 0;
  return compareByteArrays(toBytes(a), toBytes(b));
}

export function less(a, b) {
  return compare(a, b) < 0;
}

export { compareByteArrays };

// 32-bit FNV-1a over a string's bytes (or an array of bytes).
export function fnv1a32(data) {
  const bytes = typeof data === "string" ? toBytes(data) : data;
  let h = FNV_OFFSET;
  for (let i = 0; i < bytes.length; i++) {
    h = Math.imul(h ^ bytes[i], FNV_PRIME) >>> 0;
  }
  return h;
}

export function uint32be(n) {
  return [(n >>> 24) & 0xff, (n >>> 16) & 0xff, (n >>> 8) & 0xff, n & 0xff];
}

// A number with no fractional part in [lo, hi]. Booleans aren't numbers.
export function isInteger(n, lo, hi) {
  return typeof n === "number" && Number.isInteger(n) && n >= lo && n <= hi;
}

// Plain decimal, never exponent form (Util.formatInt). Exact below 2^53.
export function formatInt(n) {
  return BigInt(Math.trunc(n)).toString();
}

export function hex8(n) {
  return (n >>> 0).toString(16).padStart(8, "0");
}
