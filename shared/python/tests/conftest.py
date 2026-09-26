import json
from pathlib import Path

VECTORS = Path(__file__).resolve().parents[2] / "test-vectors"


def load(name: str) -> dict:
    return json.loads((VECTORS / name).read_text(encoding="utf-8"))


def text_input(case: dict):
    """A case's input: input (or the bytes of input_hex), repeated, then append."""
    if "input_hex" in case:
        value = bytes.fromhex(case["input_hex"]).decode("utf-8", "surrogateescape")
    else:
        value = case.get("input")
    if isinstance(value, str):
        value = value * case.get("repeat", 1) + case.get("append", "")
    return value


def record(base: dict, case: dict):
    if "input" in case:
        return case["input"]
    out = dict(base)
    out.update(case.get("patch", {}))
    for key in case.get("remove", []):
        out.pop(key, None)
    return out
