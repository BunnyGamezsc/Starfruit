#!/usr/bin/env python3
"""Package the upstream JSON-with-comments dictionaries as standard JSON."""
import json
from pathlib import Path


def remove_comments(source: str) -> str:
    result = []
    index = 0
    quoted = False
    escaped = False
    while index < len(source):
        char = source[index]
        if quoted:
            result.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
            result.append(char)
        elif source[index:index + 2] == "//":
            end = source.find("\n", index)
            index = len(source) if end < 0 else end
            continue
        elif source[index:index + 2] == "/*":
            end = source.find("*/", index + 2)
            if end < 0:
                raise ValueError("Unterminated JSON comment")
            result.append(" ")
            index = end + 2
            continue
        else:
            result.append(char)
        index += 1
    return "".join(result)


def sync() -> None:
    native = Path(__file__).resolve().parent
    source = native.parent / "i18n"
    destination = native / "Resources" / "i18n"
    destination.mkdir(parents=True, exist_ok=True)
    for file in sorted(source.glob("*.json")):
        entries = json.loads(remove_comments(file.read_text(encoding="utf-8-sig")))
        name = "en" if file.stem == "default" else file.stem
        (destination / f"{name}.json").write_text(
            json.dumps(entries, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
    print(f"Packaged {len(list(destination.glob('*.json')))} translation dictionaries")


if __name__ == "__main__":
    sync()
