"""Expose the enabled phone plugin's missing wheel documentation as a skill.

phone-harness 0.3.2's wheel omits SKILL.md, so the official plugin cannot
register it. Our unchanged reference comes from the same pinned source:
https://github.com/ShawnPana/phone-harness/blob/7e3ea6cff1377db4d4f37e852c59493120aa52b6/SKILL.md
That commit's pyproject.toml declares version 0.3.2. No user skill is copied,
overwritten or installed, and disabled/Feed tasks do not register this entry.
"""
import hashlib
from pathlib import Path

CANONICAL = 'phone-harness:phone-harness'
ALIASES = frozenset({'phone-harness', CANONICAL, 'plugin:' + CANONICAL})
SKILL_SHA256 = '45f52b2fbeeb688a0d852dec2dd551c8616c780279bf8359e941ca657f1fb8a2'


def register_phone_skill(context):
    """Register through Hermes's read-only plugin skill catalog, not user files."""
    from importlib.metadata import version
    if version('phone-harness') != '0.3.2':
        raise ValueError('Phone skill fallback requires the reviewed phone-harness version.')
    path = Path(__file__).resolve().parent / 'skills/phone-harness/SKILL.md'
    if path.is_symlink() or not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != SKILL_SHA256:
        raise ValueError('The bundled phone skill does not match the reviewed source.')
    import yaml
    text = path.read_text(encoding='utf-8')
    frontmatter = yaml.safe_load(text.split('---', 2)[1])
    return context.register_skill('phone-harness', path,
                                  description=frontmatter['description'], frontmatter=frontmatter)


def phone_skill_args(tool_name, args, *, enabled):
    """Accept the official prompt's legacy prefix and a discoverable short name."""
    if (enabled and tool_name == 'skill_view' and isinstance(args, dict)
            and isinstance(args.get('name'), str) and args['name'] in ALIASES):
        return {**args, 'name': CANONICAL}
    return args
