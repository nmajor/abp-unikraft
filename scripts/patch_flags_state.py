#!/usr/bin/env python3
import pathlib
import re
import sys

if len(sys.argv) < 2:
    print("usage: patch_flags_state.py <chromium_src_dir>", file=sys.stderr)
    sys.exit(2)

src_dir = pathlib.Path(sys.argv[1])
path = src_dir / "components/webui/flags/flags_state.cc"
if not path.exists():
    print("flags_state.cc not found; skipping robust patch")
    sys.exit(0)

text = path.read_text(encoding="utf-8")
orig = text

# Remove chrome-layer include to avoid layering violations.
text = re.sub(r"^\s*#include\s+\"chrome/browser/unexpire_flags\.h\"\s*\n", "", text, flags=re.M)

# Replace IsFlagExpired(...) with delegate-based check in the two known variants.
replacements = 0
text, n = re.subn(r"flags::IsFlagExpired\s*\(\s*flags_storage\s*,\s*entry\.internal_name\s*\)",
                  "delegate_ && delegate_->ShouldExcludeFlag(flags_storage, entry)", text)
replacements += n
text, n = re.subn(r"flags::IsFlagExpired\s*\(\s*storage\s*,\s*entry\.internal_name\s*\)",
                  "delegate_ && delegate_->ShouldExcludeFlag(storage, entry)", text)
replacements += n

# Collapse nested block to a single continue when ShouldExcludeFlag(storage, entry)
pattern = re.compile(r"""
    if\s*\(\s*delegate_\s*&&\s*delegate_->ShouldExcludeFlag\(\s*storage\s*,\s*entry\s*\)\s*\)\s*\{\s*\n    (?:[^{}]*?)\n    if\s*\(\s*!\s*flags::IsFlagExpired\(\s*storage\s*,\s*entry\.internal_name\s*\)\s*\)\s*\{\s*\n        continue;\s*\n    \}\s*\n    \}\s*\n""", re.VERBOSE)
text, n = pattern.subn("    if (delegate_ && delegate_->ShouldExcludeFlag(storage, entry)) {\n      continue;\n    }\n", text)
replacements += n

# If still present, try the variant where the inner condition already got replaced.
pattern2 = re.compile(r"""
    if\s*\(\s*delegate_\s*&&\s*delegate_->ShouldExcludeFlag\(\s*storage\s*,\s*entry\s*\)\s*\)\s*\{\s*\n    (?:[^{}]*?)\n    if\s*\(\s*!\s*delegate_\s*&&\s*delegate_->ShouldExcludeFlag\(\s*storage\s*,\s*entry\s*\)\s*\)\s*\{\s*\n        continue;\s*\n    \}\s*\n    \}\s*\n""", re.VERBOSE)
text, n = pattern2.subn("    if (delegate_ && delegate_->ShouldExcludeFlag(storage, entry)) {\n      continue;\n    }\n", text)
replacements += n

if text != orig:
    path.write_text(text, encoding="utf-8")
    print(f"flags_state.cc patched (changes: {replacements})")
else:
    print("flags_state.cc already patched or unexpected layout; no changes applied")
