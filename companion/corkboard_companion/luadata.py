"""Reading and writing Lua data files without running them (docs/design.md §7.1).

`load` parses what the client writes to SavedVariables: a series of
`Name = value` assignments whose values are strings, numbers, booleans, nil
and tables. There's no function call, operator or variable reference in that
format, so anything else is a syntax error. Strings are bytes in Lua; they
come back as str decoded with surrogateescape, like corkcore expects.

`dump` writes Python data back as a Lua assignment, for Corkboard_Cloud/Data.lua.
"""

from __future__ import annotations

import math
import re
from typing import Any

__all__ = ["LuaSyntaxError", "load", "loads", "dump", "dumps"]


class LuaSyntaxError(ValueError):
    pass


_ESCAPES = {"a": 7, "b": 8, "f": 12, "n": 10, "r": 13, "t": 9, "v": 11, "\\": 92, '"': 34, "'": 39, "\n": 10}
_NUMBER = re.compile(rb"0[xX][0-9a-fA-F]+|(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?")
_NAME = re.compile(rb"[A-Za-z_][A-Za-z0-9_]*")
_SPACE = re.compile(rb"\s+")
_LONG_OPEN = re.compile(rb"\[(=*)\[")


class _Parser:
    def __init__(self, data: bytes):
        self.s = data
        self.i = 0

    def error(self, message: str) -> LuaSyntaxError:
        line = self.s.count(b"\n", 0, self.i) + 1
        return LuaSyntaxError(f"line {line}: {message}")

    def skip(self) -> None:
        s = self.s
        while True:
            m = _SPACE.match(s, self.i)
            if m:
                self.i = m.end()
            if s.startswith(b"--", self.i):
                long = _LONG_OPEN.match(s, self.i + 2)
                if long:
                    close = b"]" + long.group(1) + b"]"
                    end = s.find(close, long.end())
                    if end < 0:
                        raise self.error("unfinished long comment")
                    self.i = end + len(close)
                else:
                    end = s.find(b"\n", self.i)
                    self.i = len(s) if end < 0 else end + 1
                continue
            return

    def peek(self) -> bytes:
        self.skip()
        return self.s[self.i:self.i + 1]

    def expect(self, token: bytes) -> None:
        self.skip()
        if not self.s.startswith(token, self.i):
            raise self.error(f"expected {token.decode()!r}")
        self.i += len(token)

    def name(self) -> str | None:
        self.skip()
        m = _NAME.match(self.s, self.i)
        if not m:
            return None
        self.i = m.end()
        return m.group().decode("ascii")

    def string(self) -> str:
        s = self.s
        quote = s[self.i:self.i + 1]
        if quote == b"[":
            m = _LONG_OPEN.match(s, self.i)
            close = b"]" + m.group(1) + b"]"
            start = m.end()
            if s.startswith(b"\r\n", start):
                start += 2
            elif s.startswith(b"\n", start):
                start += 1
            end = s.find(close, start)
            if end < 0:
                raise self.error("unfinished long string")
            self.i = end + len(close)
            return s[start:end].decode("utf-8", "surrogateescape")
        out = bytearray()
        i = self.i + 1
        while True:
            if i >= len(s):
                raise self.error("unfinished string")
            c = s[i:i + 1]
            if c == quote:
                self.i = i + 1
                return bytes(out).decode("utf-8", "surrogateescape")
            if c == b"\n":
                raise self.error("newline in string")
            if c == b"\\":
                e = s[i + 1:i + 2]
                if e.isdigit():
                    digits = re.match(rb"[0-9]{1,3}", s[i + 1:i + 4]).group()
                    value = int(digits)
                    if value > 255:
                        raise self.error("escape too large")
                    out.append(value)
                    i += 1 + len(digits)
                elif e == b"x":
                    hexits = s[i + 2:i + 4]
                    if not re.fullmatch(rb"[0-9a-fA-F]{2}", hexits):
                        raise self.error("bad \\x escape")
                    out.append(int(hexits, 16))
                    i += 4
                elif e.decode("latin-1") in _ESCAPES:
                    out.append(_ESCAPES[e.decode("latin-1")])
                    i += 2
                else:
                    raise self.error(f"bad escape \\{e.decode('latin-1')}")
            else:
                out += c
                i += 1

    def number(self, negative: bool) -> int | float:
        m = _NUMBER.match(self.s, self.i)
        if not m:
            raise self.error("expected a value")
        self.i = m.end()
        text = m.group().decode("ascii")
        if text[:2].lower() == "0x":
            value: int | float = int(text, 16)
        elif re.fullmatch(r"[0-9]+", text):
            value = int(text)
        else:
            value = float(text)
            if value.is_integer() and abs(value) < 2**53:
                value = int(value)
        return -value if negative else value

    def value(self) -> Any:
        self.skip()
        s = self.s
        c = s[self.i:self.i + 1]
        if c in (b'"', b"'") or (c == b"[" and _LONG_OPEN.match(s, self.i)):
            return self.string()
        if c == b"{":
            return self.table()
        if c == b"-":
            self.i += 1
            self.skip()
            return self.number(True)
        word = _NAME.match(s, self.i)
        if word:
            w = word.group()
            if w in (b"true", b"false", b"nil"):
                self.i = word.end()
                return {b"true": True, b"false": False, b"nil": None}[w]
            if w in (b"inf", b"nan"):
                raise self.error("not a number literal")
            raise self.error(f"unexpected name {w.decode()!r}")
        return self.number(False)

    def table(self) -> dict | list:
        self.expect(b"{")
        items: dict[Any, Any] = {}
        n = 0
        while True:
            c = self.peek()
            if c == b"}":
                self.i += 1
                break
            if c == b"[" and not _LONG_OPEN.match(self.s, self.i):
                self.i += 1
                key = self.value()
                self.expect(b"]")
                self.expect(b"=")
                val = self.value()
                if key is None:
                    raise self.error("nil table key")
                if isinstance(key, float) and key.is_integer():
                    key = int(key)
                if val is not None:
                    items[key] = val
            else:
                start = self.i
                key = self.name()
                if key is not None and self.peek() == b"=" and not self.s.startswith(b"==", self.i):
                    self.i += 1
                    val = self.value()
                    if val is not None:
                        items[key] = val
                else:
                    self.i = start
                    n += 1
                    val = self.value()
                    if val is not None:
                        items[n] = val
            c = self.peek()
            if c in (b",", b";"):
                self.i += 1
            elif c != b"}":
                raise self.error("expected ',' or '}'")
        return _listify(items)

    def chunk(self) -> dict:
        out: dict[str, Any] = {}
        while True:
            self.skip()
            if self.i >= len(self.s):
                return out
            name = self.name()
            if name is None:
                raise self.error("expected an assignment")
            self.expect(b"=")
            out[name] = self.value()
            self.skip()
            if self.s.startswith(b";", self.i):
                self.i += 1


def _listify(items: dict) -> dict | list:
    """A table whose keys are exactly 1..n becomes a list; anything else stays a dict."""
    if items and all(isinstance(k, int) and not isinstance(k, bool) for k in items):
        if sorted(items) == list(range(1, len(items) + 1)):
            return [items[k] for k in range(1, len(items) + 1)]
    return items


def loads(data: bytes | str) -> dict:
    """Parses a SavedVariables-style chunk into {global name: value}."""
    if isinstance(data, str):
        data = data.encode("utf-8", "surrogateescape")
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    return _Parser(data).chunk()


def load(path) -> dict:
    with open(path, "rb") as f:
        return loads(f.read())


# Writing -----------------------------------------------------------------------------------


def _string(s: str) -> bytes:
    raw = s.encode("utf-8", "surrogateescape")
    out = bytearray(b'"')
    for byte in raw:
        if byte == 0x5C:
            out += b"\\\\"
        elif byte == 0x22:
            out += b'\\"'
        elif byte == 0x0A:
            out += b"\\n"
        elif byte == 0x0D:
            out += b"\\r"
        elif byte < 0x20 or byte == 0x7F:
            out += b"\\%03d" % byte
        else:
            out.append(byte)
    out += b'"'
    return bytes(out)


_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
_KEYWORDS = {"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in", "local", "nil",
             "not", "or", "repeat", "return", "then", "true", "until", "while"}


def _value(v: Any, indent: str) -> bytes:
    if v is None:
        return b"nil"
    if v is True:
        return b"true"
    if v is False:
        return b"false"
    if isinstance(v, int):
        return str(v).encode()
    if isinstance(v, float):
        if math.isnan(v) or math.isinf(v):
            raise ValueError("can't write NaN or infinity")
        return (str(int(v)) if v.is_integer() and abs(v) < 2**53 else repr(v)).encode()
    if isinstance(v, str):
        return _string(v)
    if isinstance(v, (list, tuple)):
        if not v:
            return b"{}"
        inner = indent + "\t"
        parts = [inner.encode() + _value(x, inner) + b",\n" for x in v]
        return b"{\n" + b"".join(parts) + indent.encode() + b"}"
    if isinstance(v, dict):
        if not v:
            return b"{}"
        inner = indent + "\t"
        parts = []
        for k in sorted(v, key=lambda k: (not isinstance(k, str), str(k))):
            if isinstance(k, str) and _IDENT.match(k) and k not in _KEYWORDS:
                key = k.encode()
            elif isinstance(k, (str, int)) and not isinstance(k, bool):
                key = b"[" + _value(k, inner) + b"]"
            else:
                raise ValueError(f"can't write a {type(k).__name__} key")
            parts.append(inner.encode() + key + b" = " + _value(v[k], inner) + b",\n")
        return b"{\n" + b"".join(parts) + indent.encode() + b"}"
    raise ValueError(f"can't write a {type(v).__name__}")


def dumps(name: str, value: Any, header: str = "") -> bytes:
    """`name = value` as Lua source bytes, with an optional comment header."""
    if not _IDENT.match(name) or name in _KEYWORDS:
        raise ValueError("not a Lua name")
    comment = b"".join(b"-- " + line.encode("utf-8") + b"\n" for line in header.splitlines())
    return comment + name.encode() + b" = " + _value(value, "") + b"\n"


def dump(path, name: str, value: Any, header: str = "") -> None:
    with open(path, "wb") as f:
        f.write(dumps(name, value, header))
