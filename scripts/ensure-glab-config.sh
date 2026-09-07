#!/bin/bash
set -euo pipefail

# The entrypoint drops to node via setpriv, which keeps HOME=/root from the
# root phase; resolve the real home of the current uid so the seed lands in
# the node-owned per-Project volume instead of failing on /root.
config_home() {
    local home="${HOME:-}" passwd_home=''

    if [ -n "$home" ] && [ -d "$home" ] && [ -O "$home" ]; then
        printf '%s\n' "$home"
        return 0
    fi
    passwd_home="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
    printf '%s\n' "${passwd_home:-$home}"
}

readonly config_dir="${GLAB_CONFIG_DIR:-$(config_home)/.config/glab-cli}"
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


def strip_inline_comment(line: bytes) -> bytes:
    body = line.removesuffix(ending(line))
    content = body.lstrip(b" \t")
    search_from = 0

    # A quoted key may contain whitespace followed by '#', which is key data.
    if content[:1] in (b'"', b"'"):
        closing_quote = content.find(content[:1], 1)
        if closing_quote != -1:
            separator = content.find(b":", closing_quote + 1)
            if separator != -1:
                search_from = len(body) - len(content) + separator + 1

    comment = re.search(br"[ \t]+#.*$", body[search_from:])
    if comment:
        return body[: search_from + comment.start()]
    return body


def is_token_key(line: bytes, indent: bytes) -> bool:
    working_line = strip_inline_comment(line)
    key, separator, _ = working_line[len(indent) :].partition(b":")
    return bool(separator) and normalize_entry_key(key) == b"token"


def is_separator(line: bytes) -> bool:
    return not line.strip() or line.lstrip(b" \t").startswith(b"#")


def replace_default_host(line: bytes) -> bytes:
    body = line.removesuffix(ending(line))
    comment = re.search(br"[ \t]+#.*$", body)
    suffix = comment.group(0) if comment else b""
    return b"host: " + target + suffix + ending(line)


# YAML allows whitespace before the colon, so a hand-edited `host :` line is
# still the default-host key and must be rewritten rather than duplicated.
host_indexes = [
    index for index, line in enumerate(lines) if re.match(br"^host[ \t]*:", line)
]
if host_indexes:
    for index in host_indexes:
        lines[index] = replace_default_host(lines[index])
else:
    lines.insert(0, b"host: " + target + newline)

hosts_index = None
for index, line in enumerate(lines):
    if re.match(br"^hosts[ \t]*:[ \t]*(?:#.*)?(?:\r?\n)?$", line):
        hosts_index = index
        break

    body = line.removesuffix(ending(line))
    empty_flow_map = re.match(
        br"^hosts[ \t]*:[ \t]*\{[ \t]*\}([ \t]*(?:#.*)?)$", body
    )
    if empty_flow_map:
        suffix = empty_flow_map.group(1)
        comment = suffix if b"#" in suffix else b""
        lines[index] = b"hosts:" + comment + ending(line)
        hosts_index = index
        break

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
            if entry_pattern.match(strip_inline_comment(lines[index]))
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
        working_entry = strip_inline_comment(block[0])
        host = normalize_entry_key(entry_pattern.match(working_entry).group(1))
        trailing_start = len(block)
        while trailing_start > 1 and is_separator(block[trailing_start - 1]):
            trailing_start -= 1
        entry_block = block[:trailing_start]
        trailing = block[trailing_start:]
        child_indent = next(
            (
                leading_whitespace(line)
                for line in entry_block[1:]
                if not is_separator(line)
            ),
            None,
        )
        token_indexes = [
            index
            for index, line in enumerate(entry_block)
            if index > 0
            and child_indent is not None
            and leading_whitespace(line) == child_indent
            and is_token_key(line, child_indent)
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
