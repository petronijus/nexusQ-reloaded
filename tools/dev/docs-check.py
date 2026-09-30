#!/usr/bin/env python3
"""Check that the Markdown docs agree with the repo.

Only drift that can be proven without reading the prose; whether the prose
is true stays with the docs-writer agent. Every tracked or new (not ignored)
Markdown file is checked for:

- `just <recipe>` in inline code or a shell code block: the recipe, alias or
  module recipe exists in the justfile, and chained recipes too;
- relative links and images: the target exists in the repo, git does not
  ignore it, and a `#fragment` into a Markdown file names one of its headings;
- repo paths in inline code (`tools/dev/format.sh`): the path exists, unless
  git ignores it (a file the reader creates, `.claude/settings.local.json`);
- `@imports` in AGENTS.md / CLAUDE.md: the imported file exists;
- AGENTS.md and CLAUDE.md stay within MAX_LINES (always-loaded context).

    tools/dev/docs-check.py      (`just lint-docs`; the pre-commit hook)

Prints `file:line: problem` per finding and exits 1 when there is any.
`<!-- docs-check: ignore -->` on a line skips that line; on the line right
above a code fence it skips the whole block.

Python >= 3.9, standard library only.
"""

from __future__ import annotations

import bisect
import fnmatch
import json
import os
import posixpath
import re
import shlex
import subprocess
import sys
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import unquote

# Docs whose references are history, not claims about the repo today:
# changelogs, decision records, and dated records (session notes, handoffs,
# plans named `2026-09-30-…`). fnmatch patterns on repo-relative paths;
# `*` also matches `/`.
EXCLUDE = [
    "CHANGELOG.md",
    "*/CHANGELOG.md",
    "docs/adr/*",
    "*[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]*",
    # The cross-session handoff: a short standing header ("WHICH MACHINE
    # BUILDS WHAT") over thousands of lines of dated `## Session …` entries
    # that name files as they were that day (tests since moved into their
    # component, the retired pmos/python3 override). Rewriting them would
    # falsify the log; the nexusq-docs agent keeps the header current.
    "HANDOFF.md",
]
MAX_LINES = 200
INSTRUCTION_FILES = {"AGENTS.md", "CLAUDE.md"}
IGNORE_MARK = "<!-- docs-check: ignore -->"

# Code fences whose lines are shell commands. `console` and friends are
# transcripts: only the prompt lines (`$ …`) are commands there.
SHELL_FENCES = {"", "sh", "bash", "shell", "zsh", "fish", "ksh"}
TRANSCRIPT_FENCES = {
    "console",
    "shell-session",
    "sh-session",
    "shellsession",
    "terminal",
}

# `just` options that change neither the justfile nor the meaning of the
# arguments; any other option makes the invocation uncheckable.
JUST_NEUTRAL_FLAGS = {
    "-q",
    "--quiet",
    "-v",
    "-vv",
    "--verbose",
    "-n",
    "--dry-run",
    "--yes",
    "--unstable",
    "--timestamp",
    "--highlight",
    "--no-highlight",
    "--explain",
    "--no-deps",
    "--check",
    "--clear-shell-args",
}
COMMAND_WRAPPERS = {"time", "env", "command", "exec", "nohup"}
PLACEHOLDER = re.compile(r"[<>{}\[\]*?$…]|\.\.\.")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*=")
URL_SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
LINE_ANCHOR = re.compile(r"^L\d+(?:C\d+)?(?:-L\d+(?:C\d+)?)?$")


@dataclass
class Problem:
    path: str
    line: int
    message: str


@dataclass
class Fence:
    line: int  # 1-based line of the opening fence
    lang: str
    body: list[tuple[int, str]]
    ignored: bool


@dataclass
class Doc:
    path: str  # repo-relative, POSIX separators
    lines: list[str]
    prose: str = ""  # the text with front matter, code and comments blanked
    fences: list[Fence] = field(default_factory=list)
    spans: list[tuple[int, str]] = field(default_factory=list)  # inline code
    ignored: set[int] = field(default_factory=set)
    _starts: list[int] = field(default_factory=list)

    def line_of(self, offset: int) -> int:
        return bisect.bisect_right(self._starts, offset)


# ── Markdown ─────────────────────────────────────────────────────────────


FENCE_OPEN = re.compile(r"^\s*(`{3,}|~{3,})(.*)$")


def blank(text: str) -> str:
    """Spaces for every character but newlines, so offsets and lines survive."""
    return re.sub(r"[^\n]", " ", text)


def parse(path: str, text: str) -> Doc:
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    doc = Doc(path, lines)
    doc.ignored = {i + 1 for i, line in enumerate(lines) if IGNORE_MARK in line}
    masked = list(lines)

    start = 0
    if lines and lines[0].strip() == "---":  # YAML front matter
        for j in range(1, len(lines)):
            if lines[j].strip() in ("---", "..."):
                masked[: j + 1] = [""] * (j + 1)
                start = j + 1
                break

    i = start
    while i < len(lines):
        m = FENCE_OPEN.match(lines[i])
        if not m or (m.group(1)[0] == "`" and "`" in m.group(2)):
            i += 1
            continue
        marker, info = m.group(1), m.group(2).strip()
        lang = info.split()[0].strip("{}").lstrip(".").lower() if info else ""
        close = re.compile(r"^\s*" + re.escape(marker[0]) + "{" + str(len(marker)) + r",}\s*$")
        j = i + 1
        while j < len(lines) and not close.match(lines[j]):
            j += 1
        ignored = (i + 1) in doc.ignored or i in doc.ignored
        doc.fences.append(
            Fence(
                i + 1,
                lang,
                [(k + 1, lines[k]) for k in range(i + 1, min(j, len(lines)))],
                ignored,
            )
        )
        for k in range(i, min(j + 1, len(lines))):
            masked[k] = ""
        i = j + 1

    text = "\n".join(masked)
    text = re.sub(r"<!--.*?(?:-->|\Z)", lambda m: blank(m.group(0)), text, flags=re.DOTALL)
    doc._starts = [0] + [m.end() for m in re.finditer("\n", text)]

    spans, out, pos = [], [], 0
    for begin, end, content in code_spans(text):
        spans.append((doc.line_of(begin), content))
        out.append(text[pos:begin])
        out.append(blank(text[begin:end]))
        pos = end
    out.append(text[pos:])
    doc.prose = "".join(out)
    doc.spans = [(n, s) for n, s in spans if n not in doc.ignored]
    return doc


def code_spans(text: str):
    """(begin, end, content) of every CommonMark code span in `text`."""
    runs = re.compile(r"`+")
    pos = 0
    while True:
        m = runs.search(text, pos)
        if not m:
            return
        begin, n = m.start(), len(m.group(0))
        if begin > 0 and text[begin - 1] == "\\":  # an escaped backtick opens nothing
            begin, n = begin + 1, n - 1
            if n == 0:
                pos = m.end()
                continue
        para_end = re.compile(r"\n[ \t]*\n").search(text, begin + n)
        limit = para_end.start() if para_end else len(text)
        closing = None
        for c in runs.finditer(text, begin + n, limit):
            if len(c.group(0)) == n:
                closing = c
                break
        if closing is None:
            pos = begin + n
            continue
        content = text[begin + n : closing.start()].replace("\n", " ")
        if len(content) > 2 and content[0] == " " and content[-1] == " " and content.strip():
            content = content[1:-1]
        yield begin, closing.end(), content
        pos = closing.end()


def link_destinations(doc: Doc):
    """(line, destination) of inline links, images, reference definitions and HTML links."""
    prose = doc.prose
    for m in re.finditer(r"(?<!\\)\]\(", prose):
        dest = read_destination(prose, m.end())
        if dest is not None:
            yield doc.line_of(m.start()), dest
    for m in re.finditer(r"(?m)^ {0,3}\[[^\]\n]+\]:[ \t]*(<[^>\n]*>|\S+)", prose):
        yield doc.line_of(m.start(1)), m.group(1).strip("<>")
    for m in re.finditer(
        r"<(?:a|img|source)\b[^>]*?\b(?:href|src)\s*=\s*([\"'])(.*?)\1",
        prose,
        re.IGNORECASE | re.DOTALL,
    ):
        yield doc.line_of(m.start(2)), m.group(2)


def read_destination(text: str, i: int) -> str | None:
    while i < len(text) and text[i] in " \t":
        i += 1
    if i < len(text) and text[i] == "<":
        end = text.find(">", i)
        newline = text.find("\n", i)
        if end == -1 or (newline != -1 and newline < end):
            return None
        return text[i + 1 : end]
    depth, out = 0, []
    while i < len(text):
        ch = text[i]
        if ch == "\\" and i + 1 < len(text):
            out.append(text[i + 1])
            i += 2
            continue
        if ch.isspace():
            break
        if ch == "(":
            depth += 1
        elif ch == ")":
            if depth == 0:
                break
            depth -= 1
        out.append(ch)
        i += 1
    return "".join(out)


def slugs(doc: Doc) -> set[str]:
    """GitHub's heading anchors (github-slugger) plus explicit HTML ids."""
    found: set[str] = set()
    seen: dict[str, int] = {}
    prose_lines = doc.prose.split("\n")
    for i, line in enumerate(prose_lines):
        title = None
        m = re.match(r"^ {0,3}#{1,6}(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$", doc.lines[i]) if line.strip() else None
        if m:
            title = m.group(1) or ""
        elif i > 0 and re.match(r"^ {0,3}(=+|-+)[ \t]*$", line) and is_paragraph_line(prose_lines[i - 1]):
            title = doc.lines[i - 1].strip()
        if title is None:
            continue
        base = slugify(title)
        count = seen.get(base, 0)
        seen[base] = count + 1
        found.add(base if count == 0 else f"{base}-{count}")
    for m in re.finditer(
        r"""<[a-z][^>]*?\b(?:id|name)\s*=\s*(["'])(.*?)\1""",
        doc.prose,
        re.IGNORECASE | re.DOTALL,
    ):
        found.add(m.group(2))
    return found


def is_paragraph_line(line: str) -> bool:
    s = line.strip()
    return bool(s) and not re.match(r"^(#|[-*+]\s|\d+[.)]\s|>|\|)", s) and "|" not in s


def slugify(title: str) -> str:
    text = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", title)  # images: alt text
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)  # links: their text
    text = re.sub(r"<[^>]+>", "", text)  # inline HTML
    text = re.sub(r"(?<!\w)(_{1,3})(?=\S)(.+?)(?<=\S)\1(?!\w)", r"\2", text)  # _emphasis_
    text = re.sub(r"\\(.)", r"\1", text)
    text = text.lower()
    text = "".join(ch for ch in text if ch.isalnum() or ch in " _-" or unicode_mark(ch))
    return text.replace(" ", "-")


def unicode_mark(ch: str) -> bool:
    return unicodedata.category(ch).startswith("M")


# ── the repo ─────────────────────────────────────────────────────────────


class Repo:
    def __init__(self, root: Path):
        self.root = root
        self._dirs: dict[Path, set[str] | None] = {}

    def exists(self, rel: str) -> bool:
        """Exact-case existence, so a macOS clone agrees with Linux and GitHub."""
        path = self.root
        for part in rel.split("/"):
            if part in ("", "."):
                continue
            names = self._listing(path)
            if names is None or part not in names:
                return False
            path = path / part
        return True

    def is_dir(self, rel: str) -> bool:
        return (self.root / rel).is_dir()

    def _listing(self, path: Path) -> set[str] | None:
        if path not in self._dirs:
            try:
                self._dirs[path] = set(os.listdir(path))
            except OSError:
                self._dirs[path] = None
        return self._dirs[path]

    def ignored(self, rels: list[str]) -> set[str]:
        if not rels:
            return set()
        out = git(
            self.root,
            "check-ignore",
            "--no-index",
            "--stdin",
            "-z",
            stdin="\0".join(rels) + "\0",
            ok=(0, 1),
        )
        return {p for p in out.split("\0") if p}


def git(root: Path, *args: str, stdin: str | None = None, ok=(0,)) -> str:
    proc = subprocess.run(
        ["git", *args],
        cwd=root,
        input=stdin,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode not in ok:
        sys.exit(f"docs-check: git {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc.stdout


# ── just ─────────────────────────────────────────────────────────────────


@dataclass
class Module:
    # name -> how many arguments it takes at most; just hands a recipe that
    # many, and the next word after them is the next recipe (`just fmt check`)
    recipes: dict[str, float]
    aliases: dict[str, str]
    modules: dict[str, Module]

    @classmethod
    def load(cls, dump: dict) -> Module:
        recipes = {}
        for name, recipe in dump.get("recipes", {}).items():
            params = recipe.get("parameters", [])
            variadic = any(p.get("kind") in ("plus", "star") for p in params)
            recipes[name] = float("inf") if variadic else len(params)
        aliases = {name: alias["target"] for name, alias in dump.get("aliases", {}).items()}
        modules = {name: cls.load(sub) for name, sub in dump.get("modules", {}).items()}
        return cls(recipes, aliases, modules)

    def recipe(self, name: str) -> float | None:
        return self.recipes.get(self.aliases.get(name, name))


def load_justfile(root: Path) -> Module:
    try:
        proc = subprocess.run(
            ["just", "--dump", "--dump-format", "json"],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        sys.exit("docs-check: just is required (just doctor)")
    if proc.returncode != 0:
        sys.exit(f"docs-check: just cannot read the justfile:\n{proc.stderr.strip()}")
    return Module.load(json.loads(proc.stdout))


def shell_words(line: str) -> list[str]:
    # `<` and `>` stay inside words: `just test-<layer>` is a placeholder, and a
    # redirection written as its own word (`> log`) still ends the command.
    lexer = shlex.shlex(line, posix=True, punctuation_chars=";&|()")
    lexer.whitespace_split = True
    try:
        return list(lexer)
    except ValueError:  # unbalanced quotes in a doc snippet
        return line.split()


def just_invocations(line: str):
    """The argument lists of every `just` in command position on a shell line."""
    words = shell_words(line)
    command_start = True
    i = 0
    while i < len(words):
        w = words[i]
        if set(w) <= set(";&|()<>"):
            command_start = True
        elif command_start and (
            ASSIGNMENT.match(w)
            or w in COMMAND_WRAPPERS
            or (w.startswith("-") and i and words[i - 1] in COMMAND_WRAPPERS)
        ):
            pass
        elif command_start and w == "just":
            j = i + 1
            while j < len(words) and not set(words[j]) <= set(";&|()<>"):
                j += 1
            yield words[i + 1 : j]
            i = j
            continue
        else:
            command_start = False
        i += 1


def check_invocation(root: Module, args: list[str]) -> str | None:
    """None when every recipe the invocation names exists, else the problem."""
    i = 0
    while i < len(args) and (args[i].startswith("-") or ASSIGNMENT.match(args[i])):
        if args[i].startswith("-") and args[i] not in JUST_NEUTRAL_FLAGS:
            return None  # another justfile, a subcommand (--list, --show …): not ours to judge
        i += 1
    while i < len(args):
        token = args[i]
        if PLACEHOLDER.search(token) or "/" in token:
            return None
        module, path = root, token.split("::") if "::" in token else [token]
        i += 1
        while True:
            name = path[0]
            if len(path) == 1 and name in module.modules and module.recipe(name) is None:
                module = module.modules[name]
                if i >= len(args):
                    return None  # `just mod`: the module's default recipe
                if PLACEHOLDER.search(args[i]):
                    return None
                path = [args[i]]
                i += 1
                continue
            if len(path) > 1:
                if name not in module.modules:
                    return f"no module `{name}`"
                module, path = module.modules[name], path[1:]
                continue
            # Fewer arguments than the recipe needs is not a finding: prose
            # names a recipe (`just deploy`) without its arguments.
            most = module.recipe(name)
            if most is None:
                return f"no recipe `{token if '::' in token else name}`"
            i += int(min(most, len(args) - i))
            break
    return None


# ── checks ───────────────────────────────────────────────────────────────


def check_recipes(doc: Doc, just: Module) -> list[Problem]:
    commands = [(n, re.sub(r"^[$%] ", "", span.strip())) for n, span in doc.spans]
    for fence in doc.fences:
        if fence.ignored or not (fence.lang in SHELL_FENCES or fence.lang in TRANSCRIPT_FENCES):
            continue
        pending, first = "", 0
        for n, raw in fence.body:
            if n in doc.ignored:
                continue
            line = raw.strip()
            if fence.lang in TRANSCRIPT_FENCES and not pending and not line.startswith(("$ ", "% ")):
                continue
            if not pending:
                line, first = re.sub(r"^[$%] ", "", line), n
            if line.endswith("\\"):
                pending += line[:-1] + " "
                continue
            commands.append((first, pending + line))
            pending = ""
    problems = []
    for n, line in commands:
        for args in just_invocations(line):
            reason = check_invocation(just, args)
            if reason:
                shown = " ".join(["just", *args])
                problems.append(
                    Problem(
                        doc.path,
                        n,
                        f"`{shown}`: {reason} in the justfile (`just --list`)",
                    )
                )
    return problems


def resolve(doc: Doc, target: str) -> str | None:
    """Repo-relative path of a link target, None when it leaves the repo."""
    if target.startswith("/"):
        rel = posixpath.normpath(target.lstrip("/"))
    else:
        rel = posixpath.normpath(posixpath.join(posixpath.dirname(doc.path), target))
    return None if rel == ".." or rel.startswith("../") else rel


def check_links(doc: Doc, repo: Repo, docs: dict[str, Doc], anchors: dict[str, set[str]]) -> list[Problem]:
    problems, targets = [], []
    for n, dest in link_destinations(doc):
        if n in doc.ignored:
            continue
        dest = dest.strip()
        if not dest or URL_SCHEME.match(dest) or dest.startswith("//"):
            continue
        target, _, fragment = dest.partition("#")
        target = unquote(target.split("?", 1)[0])
        rel = resolve(doc, target) if target else doc.path
        if rel is None:
            continue
        if not repo.exists(rel):
            problems.append(Problem(doc.path, n, f"link `{dest}`: no such file or directory"))
            continue
        if target:
            targets.append((n, dest, rel))
        fragment = unquote(fragment)
        if not fragment or not rel.lower().endswith((".md", ".markdown")) or LINE_ANCHOR.match(fragment):
            continue
        if rel not in anchors:
            other = docs.get(rel) or parse(rel, (repo.root / rel).read_text(encoding="utf-8", errors="replace"))
            anchors[rel] = slugs(other)
        if fragment.lower() not in {a.lower() for a in anchors[rel]}:
            problems.append(Problem(doc.path, n, f"link `{dest}`: no heading `#{fragment}` in {rel}"))
    ignored = repo.ignored([rel for _, _, rel in targets])
    for n, dest, rel in targets:
        if rel in ignored:
            problems.append(
                Problem(
                    doc.path,
                    n,
                    f"link `{dest}`: git ignores {rel}, so a clone does not have it",
                )
            )
    return problems


def path_candidate(text: str) -> str | None:
    """The repo path an inline code span names, or None when it is not one.

    Only what reads unambiguously as a path: at least two segments, and a
    last segment that is a file name (`x.py`, `.env`, `Dockerfile`) or a
    directory written with its slash (`apps/api/`). That leaves out the
    look-alikes: MCP methods (`tools/list`), branches (`feat/x`), key paths.
    A leading `./` means the repo root or the doc's directory, like the
    other paths in a doc; `../` depends on the reader's directory and is not
    checked.
    """
    t = text.strip()
    if not t or re.search(r"[\s<>*?\[\]{}$~…|;&\"'`=@,#()!\\]|://|\.\.\.", t) or t.startswith(("-", "/", "../")):
        return None
    t = re.sub(r":\d+(?::\d+)?$", "", t)
    while t.startswith("./"):
        t = t[2:]
    if ":" in t:
        return None
    is_dir = t.endswith("/")
    parts = t.rstrip("/").split("/")
    if len(parts) < 2 or any(part in ("", ".", "..") for part in parts):
        return None
    last = parts[-1]
    if not (is_dir or "." in last or re.fullmatch(r"[A-Za-z]*file", last)):
        return None
    return "/".join(parts)


def check_paths(doc: Doc, repo: Repo) -> list[Problem]:
    """Inline-code paths, resolved against the doc's directory and the root.

    A path counts as a claim about this repo only when its first segment
    exists in one of those bases; `bin/tracks.py` in a doc about another
    tool's layout is left alone.
    """
    missing: list[tuple[int, str, list[str]]] = []
    here = posixpath.dirname(doc.path)
    for n, span in doc.spans:
        t = path_candidate(span)
        if t is None:
            continue
        first = t.split("/")[0]
        bases = [b for b in dict.fromkeys([here, ""]) if repo.exists(posixpath.join(b, first))]
        candidates = [posixpath.join(b, t) for b in bases]
        if candidates and not any(repo.exists(c) for c in candidates):
            missing.append((n, t, candidates))
    ignored = repo.ignored(sorted({c for _, _, cs in missing for c in cs}))
    return [
        Problem(doc.path, n, f"`{t}`: no such file or directory")
        for n, t, candidates in missing
        if not any(c in ignored for c in candidates)
    ]


def check_imports(doc: Doc, repo: Repo) -> list[Problem]:
    """`@path` imports (Claude Code memory syntax) in AGENTS.md / CLAUDE.md.

    A word counts as an import when it reads as a path once trailing
    sentence punctuation is dropped (`@AGENTS.md`, `@docs/x.md`), which
    leaves handles (`@petronijus.`) and e-mail addresses alone.
    """
    if posixpath.basename(doc.path) not in INSTRUCTION_FILES:
        return []
    problems = []
    for m in re.finditer(r"(?:^|(?<=\s))@([^\s`]+)", doc.prose):
        n = doc.line_of(m.start())
        target = m.group(1).rstrip(".,;:!?)")
        if n in doc.ignored or target.startswith(("~", "/")) or not re.search(r"[^./]\.[^./]|/", target):
            continue
        rel = resolve(doc, target)
        if rel is None or repo.exists(rel):
            continue
        problems.append(Problem(doc.path, n, f"`@{target}`: the imported file does not exist"))
    return problems


def check_size(doc: Doc) -> list[Problem]:
    if posixpath.basename(doc.path) not in INSTRUCTION_FILES:
        return []
    count = len(doc.lines) - (1 if doc.lines and doc.lines[-1] == "" else 0)
    if count <= MAX_LINES:
        return []
    return [
        Problem(
            doc.path,
            MAX_LINES + 1,
            f"{count} lines; keep it within {MAX_LINES} (loaded into every session: "
            "move detail to docs/ or .claude/rules/ and link it)",
        )
    ]


# ── main ─────────────────────────────────────────────────────────────────


def main() -> int:
    here = Path(__file__).resolve().parent
    top = subprocess.run(
        ["git", "-C", str(here), "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=False,
    )
    if top.returncode != 0:
        sys.exit("docs-check: not inside a git repository")
    root = Path(top.stdout.strip())
    repo = Repo(root)

    listed = git(
        root,
        "ls-files",
        "-z",
        "--cached",
        "--others",
        "--exclude-standard",
        "--",
        "*.md",
        "*.markdown",
    )
    paths = sorted(
        p
        for p in dict.fromkeys(listed.split("\0"))
        if p and (root / p).is_file() and not any(fnmatch.fnmatchcase(p, pat) for pat in EXCLUDE)
    )
    docs = {p: parse(p, (root / p).read_text(encoding="utf-8", errors="replace")) for p in paths}
    just = load_justfile(root)

    problems: list[Problem] = []
    anchors: dict[str, set[str]] = {}
    for doc in docs.values():
        problems += check_recipes(doc, just)
        problems += check_links(doc, repo, docs, anchors)
        problems += check_paths(doc, repo)
        problems += check_imports(doc, repo)
        problems += check_size(doc)

    for p in sorted(problems, key=lambda p: (p.path, p.line, p.message)):
        print(f"{p.path}:{p.line}: {p.message}")
    if problems:
        files = len({p.path for p in problems})
        print(
            f"docs-check: {len(problems)} problem(s) in {files} file(s). Fix the doc (or the reference);"
            f" mark an intentional one with {IGNORE_MARK}"
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
