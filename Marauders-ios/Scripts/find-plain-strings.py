#!/usr/bin/env python3
"""Finds user-facing texts that Xcode cannot put into the string catalog.

A literal in a SwiftUI view (`Text("Feed")`) or in `String(localized:)` is extracted into
`Marauders/Resources/Localizable.xcstrings` and gets a Thai text. A plain `String` literal is not: it stays English on
a Thai screen. This scan lists the plain literals that read like text, so they can be given `String(localized:)`.

    python3 Marauders-ios/Scripts/find-plain-strings.py

Run it by hand, before a TestFlight build; it is not part of the build. It prints one `path:line: "text"` per literal
and exits 1 when it found one. A text no viewer reads goes into `Scripts/plain-strings-allowlist.txt` with its reason.

A literal is reported when it
  - reads like text: it starts with a capital letter, `%` or an interpolation and has a lowercase word after a space
    ("Sign in required", "\\(kilometers) km"), or it is one capitalised word ("Download"), a word with an ellipsis
    ("Uploading… \\(percent)%") or a title of capitalised words ("Try Again");
  - is not an argument that SwiftUI or Foundation localizes (`Text`, `Button`, `navigationTitle`,
    `String(localized:)` and the like). A literal after `??`, or in a conditional whose other branch is not a literal,
    is a plain `String` even there, and so is a literal in a closure or an array inside such a call;
  - is not logging, an assertion, an accessibility identifier or a URL.
Comments, `#Preview` bodies, multi-line literals and raw strings are skipped.

The tests are in `Scripts/tests/find-plain-strings-tests.sh`.
"""

import argparse
import os
import re
import sys
from collections import namedtuple

# The folders that are scanned, under the base folder.
ROOTS = ("Marauders", os.path.join("Packages", "MaraudersAuth", "Sources"))

# Calls whose text argument is a LocalizedStringKey or a localized resource...
LOCALIZABLE_CALLS = frozenset(
    """
    Text Button Label Toggle Section TextField SecureField Picker Menu NavigationLink LabeledContent Link ProgressView
    ContentUnavailableView DisclosureGroup Stepper Gauge GroupBox ShareLink PhotosPicker Tab Marker Annotation
    LocalizedStringKey LocalizedStringResource NSLocalizedString navigationTitle navigationBarTitle accessibilityLabel
    accessibilityHint accessibilityValue alert confirmationDialog searchable help badge accessibilityAction
    """.split()
)
# ...when it is the unlabelled argument or sits behind one of these labels.
LOCALIZABLE_LABELS = frozenset([None, "title", "titleKey", "prompt", "message"])

# An argument behind one of these labels is localized already (`localized`) or never a text for the viewer.
NEVER_TEXT_LABELS = frozenset(
    "localized systemImage systemName named forKey id identifier subsystem category forHTTPHeaderField".split()
)

# Calls whose literals the viewer never reads: assertions, identifiers, URLs, `print` and every `AppLog` method.
EXEMPT_CALLS = frozenset(
    "print assert assertionFailure precondition preconditionFailure fatalError accessibilityIdentifier URL URLRequest"
    .split()
)
LOGGER = "AppLog"

# Stands for an interpolation when a literal is judged.
PLACEHOLDER = "§"

ONE_WORD = re.compile(r"[A-Z][a-z]{2,}…?\Z")
WORD_WITH_ELLIPSIS = re.compile(r"[A-Z][a-z]{2,}…")
TITLE = re.compile(r"[A-Z][a-z]+(?: [A-Z][a-z]+)+…?\Z")
STARTS_LIKE_TEXT = re.compile(r"[A-Z%" + PLACEHOLDER + "]")
LOWERCASE_WORD_AFTER_A_SPACE = re.compile(r" [a-z]{2,}")
RAW_STRING_START = re.compile(r'(#+)"')
ALLOWLIST_REASON = re.compile(r"\s{2,}#")

# One string literal: where it is, its text as written and with interpolations replaced, the name of the call it is
# an argument of ("" when it is not an argument), and the indices of its quotes.
Literal = namedtuple("Literal", "line raw text callee start end")


class SwiftLiterals:
    """The single-line string literals of one Swift source."""

    def __init__(self, source):
        self.source = source
        self.found = []
        self._code(0, 1, interpolation=False, muted=False)
        self.found.sort(key=lambda literal: literal.start)

    def _code(self, i, line, interpolation, muted):
        """Reads code from `i`. In an interpolation it stops after the parenthesis that closes it."""
        source, n = self.source, len(self.source)
        brackets = []  # the open (, [ and {, each with the name of the call it belongs to
        preview_at = None  # the depth at which a #Preview was seen whose body has not begun
        preview_body = None  # the depth of the brackets inside a #Preview body
        while i < n:
            c = source[i]
            if c == "\n":
                line += 1
                i += 1
            elif source.startswith("//", i):
                end = source.find("\n", i)
                i = n if end < 0 else end
            elif source.startswith("/*", i):
                i, line = self._block_comment(i, line)
            elif source.startswith("#Preview", i):
                preview_at = len(brackets)
                i += len("#Preview")
            elif c == "#" and RAW_STRING_START.match(source, i):
                i, line = self._raw_string(i, line)
            elif c == '"':
                skipped = muted or preview_at is not None or preview_body is not None
                i, line = self._string(i, line, brackets, skipped)
            elif c in "([{":
                brackets.append((c, self._callee(i) if c == "(" else None))
                if preview_at is not None and c == "{" and len(brackets) == preview_at + 1:
                    preview_at, preview_body = None, len(brackets)
                i += 1
            elif c in ")]}":
                if interpolation and c == ")" and not brackets:
                    return i + 1, line
                if brackets:
                    brackets.pop()
                if preview_body is not None and len(brackets) < preview_body:
                    preview_body = None
                i += 1
            else:
                i += 1
        return i, line

    def _block_comment(self, i, line):
        source, n = self.source, len(self.source)
        depth = 0
        while i < n:
            if source.startswith("/*", i):
                depth += 1
                i += 2
            elif source.startswith("*/", i):
                depth -= 1
                i += 2
                if depth == 0:
                    break
            else:
                if source[i] == "\n":
                    line += 1
                i += 1
        return i, line

    def _raw_string(self, i, line):
        hashes = RAW_STRING_START.match(self.source, i).group(1)
        end = self.source.find('"' + hashes, i + len(hashes) + 1)
        end = len(self.source) if end < 0 else end + 1 + len(hashes)
        return end, line + self.source.count("\n", i, end)

    def _string(self, i, line, brackets, skipped):
        """Reads the literal whose opening quote is at `i`; records it unless it is skipped or has several lines."""
        source, n = self.source, len(self.source)
        if source.startswith('"""', i):
            end = source.find('"""', i + 3)
            end = n if end < 0 else end + 3
            return end, line + source.count("\n", i, end)
        text = []
        j = i + 1
        while j < n and source[j] not in '"\n':
            if source.startswith("\\(", j):
                j, line = self._code(j + 2, line, interpolation=True, muted=skipped)
                text.append(PLACEHOLDER)
            elif source[j] == "\\":
                text.append(source[j : j + 2])
                j += 2
            else:
                text.append(source[j])
                j += 1
        if j >= n or source[j] != '"':
            return j, line  # not closed on its line: not a literal this scan understands
        if not skipped:
            self.found.append(Literal(line, source[i + 1 : j], "".join(text), self._enclosing_call(brackets), i, j))
        return j + 1, line

    def _callee(self, i):
        """The name in front of the parenthesis at `i` ("AppLog.info"), or "" for a parenthesis that calls nothing."""
        j = i
        while j > 0 and (self.source[j - 1].isalnum() or self.source[j - 1] in "_."):
            j -= 1
        return self.source[j:i].strip(".")

    @staticmethod
    def _enclosing_call(brackets):
        """The call a literal is a direct argument of: none inside a closure, an array or a subscript."""
        for bracket, callee in reversed(brackets):
            if bracket == "(" and callee:
                return callee
            if bracket != "(":
                return ""
        return ""


def position(source, literal):
    """What stands in front of a literal: (its argument label, it follows `??`, it is one branch of a conditional
    whose other branch is not a literal)."""

    def back(j):
        while j >= 0 and source[j].isspace():
            j -= 1
        return j

    def forward(j):
        while j < len(source) and source[j].isspace():
            j += 1
        return j

    j = back(literal.start - 1)
    if j < 0:
        return None, False, False
    if source[j] == "?":
        if j > 0 and source[j - 1] == "?":
            return None, True, False
        k = forward(literal.end + 1)
        other_is_literal = source.startswith(":", k) and source.startswith('"', forward(k + 1))
        return None, False, not other_is_literal
    if source[j] == ":":
        k = back(j - 1)
        if k >= 0 and source[k] == '"':
            return None, False, False
        end = k + 1
        while k >= 0 and (source[k].isalnum() or source[k] == "_"):
            k -= 1
        name = source[k + 1 : end]
        k = back(k)
        if name and k >= 0 and source[k] in "(,":
            return name, False, False
        return None, False, True
    return None, False, False


def reads_like_text(text):
    if ONE_WORD.match(text) or WORD_WITH_ELLIPSIS.match(text) or TITLE.match(text):
        return True
    return bool(STARTS_LIKE_TEXT.match(text)) and LOWERCASE_WORD_AFTER_A_SPACE.search(text) is not None


def plain_literals(source):
    """The literals of a Swift source that read like text and that nothing localizes."""
    for literal in SwiftLiterals(source).found:
        label, after_fallback, mixed_conditional = position(source, literal)
        if label in NEVER_TEXT_LABELS:
            continue
        if literal.callee:
            names = literal.callee.split(".")
            if names[-1] in EXEMPT_CALLS or LOGGER in names[:-1]:
                continue
            localized = names[-1] in LOCALIZABLE_CALLS and label in LOCALIZABLE_LABELS
            if localized and not after_fallback and not mixed_conditional:
                continue
        if reads_like_text(literal.text):
            yield literal


def read_allowlist(path):
    """(the files that are skipped whole, the (file, text) pairs that are skipped)."""
    files, texts = set(), set()
    if not os.path.exists(path):
        return files, texts
    with open(path, encoding="utf-8") as lines:
        for line in lines:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            entry = ALLOWLIST_REASON.split(line, maxsplit=1)[0].rstrip()
            file, separator, text = entry.partition("|")
            if not separator:
                continue
            if text == "*":
                files.add(file.strip())
            else:
                texts.add((file.strip(), text))
    return files, texts


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    parser = argparse.ArgumentParser(description="List user-facing texts that Xcode cannot put into the catalog.")
    parser.add_argument("--base", default=os.path.dirname(here), help="the folder that holds Marauders/ and Packages/")
    parser.add_argument(
        "--allowlist",
        default=os.path.join(here, "plain-strings-allowlist.txt"),
        help="lines of `path|text  # reason`, or `path|*` for a whole file",
    )
    arguments = parser.parse_args()

    skipped_files, skipped_texts = read_allowlist(arguments.allowlist)
    hits = []
    for root in ROOTS:
        for folder, _, names in os.walk(os.path.join(arguments.base, root)):
            for name in names:
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(folder, name)
                file = os.path.relpath(path, arguments.base).replace(os.sep, "/")
                if file in skipped_files:
                    continue
                with open(path, encoding="utf-8") as swift:
                    source = swift.read()
                for literal in plain_literals(source):
                    if (file, literal.raw) not in skipped_texts:
                        hits.append((file, literal.line, literal.start, literal.raw))

    for file, line, _, raw in sorted(hits):
        print(f'{file}:{line}: "{raw}"')
    if hits:
        print(f"{len(hits)} plain strings")
        return 1
    print("OK: no plain strings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
