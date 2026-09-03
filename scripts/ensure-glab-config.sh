#!/bin/bash
set -euo pipefail

readonly config_dir="${GLAB_CONFIG_DIR:-$HOME/.config/glab-cli}"
readonly config_file="$config_dir/config.yml"

[ -n "${GITLAB_HOST:-}" ] || exit 0

mkdir -p "$config_dir"
umask 077

if [ ! -e "$config_file" ]; then
    printf 'host: %s\nhosts:\n  %s:\n' "$GITLAB_HOST" "$GITLAB_HOST" \
        > "$config_file"
    chmod 0600 "$config_file"
    exit 0
fi

# Byte-oriented parsing preserves user-managed host blocks without a YAML dependency.
temp_file="$(mktemp "$config_dir/.config.yml.XXXXXX")"
readonly temp_file
trap 'rm -f "$temp_file"' EXIT
python3 - "$config_file" "$temp_file" <<'PY'
import os
import re
import sys

source_path, output_path = sys.argv[1:]
target = os.environ["GITLAB_HOST"].encode()
remove_target_token = "GITLAB_TOKEN" in os.environ

with open(source_path, "rb") as source:
    lines = source.read().splitlines(keepends=True)

newline = b"\r\n" if any(line.endswith(b"\r\n") for line in lines) else b"\n"


def ending(line: bytes) -> bytes:
    if line.endswith(b"\r\n"):
        return b"\r\n"
    if line.endswith(b"\n"):
        return b"\n"
    return b""


def leading_whitespace(line: bytes) -> bytes:
    return re.match(br"^[ \t]*", line).group(0)


def normalize_entry_key(key: bytes) -> bytes:
    key = key.strip()
    if len(key) >= 2 and key[:1] == key[-1:] and key[:1] in (b'"', b"'"):
        key = key[1:-1]
    return key


def is_separator(line: bytes) -> bool:
    return not line.strip() or line.lstrip(b" \t").startswith(b"#")


def replace_default_host(line: bytes) -> bytes:
    body = line.removesuffix(ending(line))
    comment = re.search(br"[ \t]+#.*$", body)
    suffix = comment.group(0) if comment else b""
    return b"host: " + target + suffix + ending(line)


host_indexes = [
    index for index, line in enumerate(lines) if re.match(br"^host:[ \t]*", line)
]
if host_indexes:
    for index in host_indexes:
        lines[index] = replace_default_host(lines[index])
else:
    lines.insert(0, b"host: " + target + newline)

hosts_index = next(
    (
        index
        for index, line in enumerate(lines)
        if re.match(br"^hosts:[ \t]*(?:#.*)?(?:\r?\n)?$", line)
    ),
    None,
)

if hosts_index is None:
    if lines and not ending(lines[-1]):
        lines[-1] += newline
    lines.extend((b"hosts:" + newline, b"  " + target + b":" + newline))
else:
    section_end = len(lines)
    for index in range(hosts_index + 1, len(lines)):
        line = lines[index]
        if line.strip() and not line.startswith((b" ", b"\t", b"#")):
            section_end = index
            break

    entry_indent = None
    for index in range(hosts_index + 1, section_end):
        line = lines[index]
        if line.strip() and not line.lstrip(b" \t").startswith(b"#"):
            entry_indent = leading_whitespace(line)
            break

    if entry_indent is None:
        entry_indexes = []
    else:
        entry_pattern = re.compile(
            br"^"
            + re.escape(entry_indent)
            + br"([^ \t#].*):[ \t]*(?:#.*)?(?:\r?\n)?$"
        )
        entry_indexes = [
            index
            for index in range(hosts_index + 1, section_end)
            if entry_pattern.match(lines[index])
        ]

    append_indent = entry_indent if entry_indexes else b"  "
    rebuilt = lines[hosts_index + 1 : entry_indexes[0] if entry_indexes else section_end]
    found_target = False

    for position, entry_index in enumerate(entry_indexes):
        next_index = (
            entry_indexes[position + 1]
            if position + 1 < len(entry_indexes)
            else section_end
        )
        block = lines[entry_index:next_index]
        host = normalize_entry_key(entry_pattern.match(block[0]).group(1))
        trailing_start = len(block)
        while trailing_start > 1 and is_separator(block[trailing_start - 1]):
            trailing_start -= 1
        entry_block = block[:trailing_start]
        trailing = block[trailing_start:]
        token_indexes = [
            index
            for index, line in enumerate(entry_block)
            if index > 0
            and leading_whitespace(line).startswith(entry_indent)
            and len(leading_whitespace(line)) > len(entry_indent)
            and re.match(br"^token:", line[len(leading_whitespace(line)) :])
        ]

        if host == target:
            found_target = True
            if remove_target_token:
                entry_block = [
                    line
                    for index, line in enumerate(entry_block)
                    if index not in token_indexes
                ]
            rebuilt.extend(entry_block)
        elif token_indexes:
            rebuilt.extend(entry_block)

        # Inter-entry context must survive even when the preceding host is pruned.
        rebuilt.extend(trailing)

    if not found_target:
        if rebuilt and not ending(rebuilt[-1]):
            rebuilt[-1] += newline
        elif not rebuilt and not ending(lines[hosts_index]):
            lines[hosts_index] += newline
        rebuilt.append(append_indent + target + b":" + newline)

    lines[hosts_index + 1 : section_end] = rebuilt

with open(output_path, "wb") as output:
    output.write(b"".join(lines))
PY

# Avoid replacing an already-correct file so repeated starts do not churn its inode.
if ! cmp -s "$config_file" "$temp_file"; then
    mv "$temp_file" "$config_file"
fi
chmod 0600 "$config_file"
