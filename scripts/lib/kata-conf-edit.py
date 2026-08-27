#!/usr/bin/env python3
"""kata-conf-edit.py -- derive a second Kata configuration.toml from a first.

Why not a TOML library: Kata's configuration.toml is ~800 lines of which ~90%
is comment, and every one of those comments is load-bearing for whoever reads
the file next.  tomlkit is not in a stock Ubuntu image and tomllib is read-only,
so round-tripping through a parser would either add a dependency or throw the
documentation away.  This edits LINES, inside the section the key belongs to,
and leaves everything it did not name byte-identical.

It is deliberately small and deliberately strict: every operation either finds
what it was told to find or exits non-zero, so the caller's asserts have
something to assert against.

  --set          SECTION:KEY=VALUE    scalar; quoted unless it is a number/bool
  --append-list  SECTION:KEY=ITEM     add ITEM to a TOML array if absent
  --append-words SECTION:KEY=WORD     add WORD to a space-separated string if absent
  --comment-out  SECTION:KEY          comment the key out if it is live

A key may be present-and-commented in the template (Kata ships many that way);
--set and the append operations uncomment it in place, which keeps the key next
to the paragraph of comment that explains it.
"""
import argparse, re, sys


def parse_sections(lines):
    """-> list of (section_name, start_idx, end_idx) covering the whole file."""
    marks = [(i, m.group(1)) for i, l in enumerate(lines)
             for m in [re.match(r'\s*\[([^\[\]]+)\]\s*$', l)] if m]
    out, prev = [], None
    for idx, (i, name) in enumerate(marks):
        end = marks[idx + 1][0] if idx + 1 < len(marks) else len(lines)
        out.append((name, i + 1, end))
    return out


def find_key(lines, section, key):
    """-> (index, is_commented) of the first occurrence of key in section."""
    for name, s, e in parse_sections(lines):
        if name != section:
            continue
        for i in range(s, e):
            m = re.match(r'(\s*)(#\s*)?' + re.escape(key) + r'\s*=', lines[i])
            if m:
                return i, bool(m.group(2))
    return None, False


def section_start(lines, section):
    for name, s, e in parse_sections(lines):
        if name == section:
            return s
    return None


def quote(v):
    if re.fullmatch(r'-?\d+', v) or v in ('true', 'false'):
        return v
    return '"%s"' % v


def op_set(lines, section, key, value):
    i, _ = find_key(lines, section, key)
    if i is None:
        s = section_start(lines, section)
        if s is None:
            sys.exit("kata-conf-edit: no section [%s] in the template" % section)
        lines.insert(s, '%s = %s\n' % (key, quote(value)))
        return
    indent = re.match(r'(\s*)', lines[i]).group(1)
    lines[i] = '%s%s = %s\n' % (indent, key, quote(value))


def op_append_list(lines, section, key, item):
    i, commented = find_key(lines, section, key)
    if i is None:
        s = section_start(lines, section)
        if s is None:
            sys.exit("kata-conf-edit: no section [%s] in the template" % section)
        lines.insert(s, '%s = ["%s"]\n' % (key, item))
        return
    indent = re.match(r'(\s*)', lines[i]).group(1)
    rhs = lines[i].split('=', 1)[1].strip()
    if commented or rhs in ('[]', ''):
        items = []
    else:
        items = [x.strip().strip('"\'') for x in rhs.strip('[]').split(',') if x.strip()]
    if item not in items:
        items.append(item)
    lines[i] = '%s%s = [%s]\n' % (indent, key, ', '.join('"%s"' % x for x in items))


def op_append_words(lines, section, key, word):
    i, commented = find_key(lines, section, key)
    if i is None:
        s = section_start(lines, section)
        if s is None:
            sys.exit("kata-conf-edit: no section [%s] in the template" % section)
        lines.insert(s, '%s = "%s"\n' % (key, word))
        return
    indent = re.match(r'(\s*)', lines[i]).group(1)
    rhs = lines[i].split('=', 1)[1].strip()
    cur = '' if commented else rhs.strip().strip('"\'')
    words = cur.split()
    if word not in words:
        words.append(word)
    lines[i] = '%s%s = "%s"\n' % (indent, key, ' '.join(words))


def op_comment_out(lines, section, key):
    i, commented = find_key(lines, section, key)
    if i is None or commented:
        return
    lines[i] = '# ' + lines[i]


def split_spec(spec, with_value=True):
    section, rest = spec.split(':', 1)
    if not with_value:
        return section, rest
    key, value = rest.split('=', 1)
    return section, key, value


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--in', dest='src', required=True)
    ap.add_argument('--out', dest='dst', required=True)
    ap.add_argument('--set', action='append', default=[])
    ap.add_argument('--append-list', action='append', default=[])
    ap.add_argument('--append-words', action='append', default=[])
    ap.add_argument('--comment-out', action='append', default=[])
    a = ap.parse_args()

    lines = open(a.src).readlines()
    header = [
        '# configuration-nvkvm.toml -- GENERATED by scripts/nvkvm-kata-install.sh\n',
        '#\n',
        '# A SECOND Kata configuration, derived from:\n',
        '#   %s\n' % a.src,
        '# The stock configuration.toml is untouched, which is what makes the\n',
        '# choice between stock Kata and nvkvm-Kata per container rather than\n',
        '# global.  This file is selected by KATA_CONF_FILE, set by the wrapper\n',
        '# at /usr/local/bin/containerd-shim-<runtime>-v2.\n',
        '#\n',
        '# Edit it by hand if you like -- nothing regenerates it behind your back;\n',
        '# re-running the installer overwrites it only if it differs from what the\n',
        '# installer would produce.  docs/install.md sec 5 lists every changed key.\n',
        '#\n',
    ]

    for spec in a.set:
        op_set(lines, *split_spec(spec))
    for spec in a.append_list:
        op_append_list(lines, *split_spec(spec))
    for spec in a.append_words:
        op_append_words(lines, *split_spec(spec))
    for spec in a.comment_out:
        op_comment_out(lines, *split_spec(spec, with_value=False))

    open(a.dst, 'w').writelines(header + lines)


if __name__ == '__main__':
    main()
