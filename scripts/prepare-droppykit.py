"""Prepare an isolated SDK copy for Apple's Command Line Tools (no SwiftUIMacros).

Only the three Bool ContainerValues @Entry expansions in SDK 1.20.1 are replaced.
The public computed properties retain their names/types; the host still supplies
its own unmodified DroppyKit framework at runtime.
"""
from pathlib import Path
import shutil
import sys

source, target = map(Path, sys.argv[1:])
if source.resolve() == target.resolve():
    raise SystemExit('SDK source and compatibility copy must differ')
if target.exists():
    shutil.rmtree(target)
shutil.copytree(source, target, ignore=shutil.ignore_patterns('.git', '.build', '.DS_Store'))
p = target / 'Sources/DroppyKit/DesignSystem/SettingsRows.swift'
s = p.read_text()
names = ['dropletSettingsPaneIsNative', 'isSettingsRowDivider', 'settingsRowJoinsPrevious']
for name in names:
    original = f'@Entry var {name}: Bool = false'
    if s.count(original) != 1:
        raise SystemExit(f'SDK changed: expected one {original}')
    s = s.replace(original, f'''var {name}: Bool {{
        get {{ self[SeaCoffeeEntry_{name}.self] }}
        set {{ self[SeaCoffeeEntry_{name}.self] = newValue }}
    }}''')
    s += f'''
@available(macOS 15.0, *)
private struct SeaCoffeeEntry_{name}: ContainerValueKey {{
    static let defaultValue = false
}}
'''
p.write_text(s)
print('Prepared DroppyKit: three ContainerValues entries expanded for CLT')

# Preserve compiler diagnostics; upstream silences SwiftPM stdout, including errors.
build = target / 'Scripts/build-droplet.sh'
text = build.read_text().replace('        >/dev/null)', '        1>&2)').replace('        >/dev/null\n', '        1>&2\n')
text = text.replace('rm -rf "$BUILD_ROOT" "$BUNDLE"', 'rm -rf "$BUNDLE"')
build.write_text(text)
