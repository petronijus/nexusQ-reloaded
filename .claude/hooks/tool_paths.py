#!/usr/bin/env python3
"""Which files does a tool call write, and which does it name?

Shared by guard-edits.sh (PreToolUse) and format-edited.sh (PostToolUse).
Reads the hook's JSON from stdin and prints one line per path:

    E<TAB>/abs/path   an edit tool writes this file (its content came from the model)
    W<TAB>/abs/path   a Bash command writes, moves or truncates this file
    R<TAB>/abs/path   a Bash command prints this existing file into its output
                      (cat, grep, head, sed, jq, git diff, …) — which is how a
                      file's content reaches the conversation. Naming a file
                      for a program to consume (`source .env`,
                      `--env-file .env`) is not reading it.

Edit, Write and NotebookEdit name their file directly. For Bash the command
is lexed the way the shell splits it (quotes, escapes, line continuations,
heredocs, `$(…)` and backticks, unquoted globs) and read for the ways agents
actually write files: redirections (`>`, `>>`, `&>`, `>|`), `tee`,
`sed -i`, `perl -i`, `cp`/`mv`/`install`/`ln`/`rsync`, `dd of=`,
`truncate`, nested `bash -c '…'`, and `cd` between commands. Remote
targets (`host:/path` for rsync and scp) are not local files and are skipped.

This is best effort, not a sandbox: a program that opens a file itself
(`python -c`, `node -e`, `xargs sed -i`, a script) is invisible here. What
the hooks guard must also be kept out of reach otherwise (gitignore,
1Password).

Plain python3 >= 3.9 (macOS /usr/bin/python3), standard library only.
"""

from __future__ import annotations

import glob
import json
import os
import re
import sys
from typing import NamedTuple

# Longest first, so `&>>` wins over `&>` and `&`.
OPERATORS = sorted(
    [
        "&&",
        "||",
        ";;",
        "|&",
        "&>>",
        "&>",
        ">>",
        ">|",
        ">&",
        "<&",
        "<<<",
        "<<-",
        "<<",
        "<>",
        ";",
        "&",
        "|",
        "(",
        ")",
        "<",
        ">",
    ],
    key=len,
    reverse=True,
)
SEPARATORS = {";", ";;", "&&", "||", "|", "|&", "&", "(", ")"}
# Words that run the rest of the line as a command.
PREFIXES = {"sudo", "doas", "env", "command", "builtin", "exec", "time", "nice", "nohup"}
SHELLS = {"sh", "bash", "zsh", "dash"}
# Commands whose output is (part of) the files they are given.
READERS = {
    "cat",
    "bat",
    "batcat",
    "tac",
    "nl",
    "head",
    "tail",
    "less",
    "more",
    "most",
    "grep",
    "egrep",
    "fgrep",
    "rg",
    "ag",
    "ack",
    "sed",
    "gsed",
    "awk",
    "gawk",
    "mawk",
    "cut",
    "sort",
    "uniq",
    "paste",
    "column",
    "fold",
    "diff",
    "colordiff",
    "sdiff",
    "strings",
    "xxd",
    "hexdump",
    "od",
    "base64",
    "base32",
    "jq",
    "yq",
    "tomlq",
    "xq",
    "view",
    "vim",
    "vi",
    "nano",
    "emacs",
    "openssl",
    "keytool",
    "plutil",
    "iconv",
    "tr",
}
# `git <subcommand>` that prints file contents.
GIT_READERS = {"show", "diff", "blame", "log", "grep", "cat-file"}
REMOTE = re.compile(r"^(?:[A-Za-z0-9_.+-]+@)?[A-Za-z0-9_.-]+:(?!//)")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=")
GLOB = set("*?[")


class Word(NamedTuple):
    text: str  # value after quote removal; substitutions left as `$(…)`
    glob: bool  # contains a glob character outside quotes
    dynamic: bool  # contains a parameter or command substitution


class Op(NamedTuple):
    text: str


class Lexer:
    """A shell lexer just deep enough to find words, operators and the
    commands hidden in substitutions. Raises ValueError on unbalanced quotes."""

    def __init__(self, source: str, start: int = 0, nested: bool = False):
        self.s = source
        self.i = start
        self.nested = nested  # inside `$(`: stop at the unmatched `)`
        self.tokens: list[Word | Op] = []
        self.subcommands: list[str] = []
        self.heredocs: list[tuple[str, bool]] = []  # (delimiter, strip tabs)

    def run(self) -> Lexer:
        buf, glob_, dyn, started = [], False, False, False

        def end_word() -> None:
            nonlocal buf, glob_, dyn, started
            if started:
                self.tokens.append(Word("".join(buf), glob_, dyn))
            buf, glob_, dyn, started = [], False, False, False

        s, depth = self.s, 0
        while self.i < len(s):
            c = s[self.i]
            if c == "\n":
                end_word()
                self.tokens.append(Op(";"))
                self.i += 1
                self.skip_heredoc_bodies()
            elif c in " \t":
                end_word()
                self.i += 1
            elif c == "#" and not started:
                while self.i < len(s) and s[self.i] != "\n":
                    self.i += 1
            elif c == "\\":
                if s[self.i + 1 : self.i + 2] == "\n":
                    self.i += 2  # line continuation
                else:
                    buf.append(s[self.i + 1 : self.i + 2])
                    started, self.i = True, self.i + 2
            elif c == "'":
                end = s.find("'", self.i + 1)
                if end < 0:
                    raise ValueError("unbalanced single quote")
                buf.append(s[self.i + 1 : end])
                started, self.i = True, end + 1
            elif c == '"':
                dyn = self.double_quoted(buf) or dyn
                started = True
            elif s.startswith("$(", self.i) or c == "`":
                self.substitution()
                buf.append("$(…)")
                started = dyn = True
            elif c == "$":
                buf.append(c)
                started = dyn = True
                self.i += 1
            elif c in ";&|<>()":
                op = next(o for o in OPERATORS if s.startswith(o, self.i))
                # `2>`: a descriptor number glued to a redirection is not a word.
                if op[0] in "<>" and started and "".join(buf).isdigit():
                    buf, started = [], False
                end_word()
                self.i += len(op)
                if op == ")" and self.nested and depth == 0:
                    return self
                depth += {"(": 1, ")": -1}.get(op, 0)
                if op in ("<<", "<<-"):
                    self.heredoc_delimiter(strip=op == "<<-")
                else:
                    self.tokens.append(Op(op))
            else:
                glob_ = glob_ or c in GLOB
                buf.append(c)
                started, self.i = True, self.i + 1
        if self.nested:
            raise ValueError("unbalanced $(")
        end_word()
        return self

    def double_quoted(self, buf: list[str]) -> bool:
        s, dyn = self.s, False
        self.i += 1
        while self.i < len(s) and s[self.i] != '"':
            c = s[self.i]
            if c == "\\" and self.i + 1 < len(s):
                nxt = s[self.i + 1]
                if nxt == "\n":
                    pass
                elif nxt in '"\\$`':
                    buf.append(nxt)
                else:
                    buf.append(c + nxt)
                self.i += 2
            elif s.startswith("$(", self.i) or c == "`":
                self.substitution()
                buf.append("$(…)")
                dyn = True
            else:
                dyn = dyn or c == "$"
                buf.append(c)
                self.i += 1
        if self.i >= len(s):
            raise ValueError("unbalanced double quote")
        self.i += 1
        return dyn

    def substitution(self) -> None:
        """Consume `$(…)` or `…` and remember the command inside."""
        s = self.s
        if s[self.i] == "`":
            end = s.find("`", self.i + 1)
            if end < 0:
                raise ValueError("unbalanced backtick")
            self.subcommands.append(s[self.i + 1 : end])
            self.i = end + 1
            return
        # A nested lexer finds the closing `)`, so quotes, heredocs and
        # parentheses inside the substitution cannot fool the count.
        inner = Lexer(s, self.i + 2, nested=True).run()
        self.subcommands.append(s[self.i + 2 : inner.i - 1])
        self.i = inner.i

    def heredoc_delimiter(self, strip: bool) -> None:
        s = self.s
        while self.i < len(s) and s[self.i] in " \t":
            self.i += 1
        m = re.match(r"""(['"]?)([^\s;&|<>()'"]+)\1""", s[self.i :])
        if m:
            self.heredocs.append((m.group(2), strip))
            self.i += m.end()

    def skip_heredoc_bodies(self) -> None:
        s = self.s
        while self.heredocs:
            delimiter, strip = self.heredocs.pop(0)
            while self.i < len(s):
                end = s.find("\n", self.i)
                line = s[self.i : end if end >= 0 else len(s)]
                self.i = end + 1 if end >= 0 else len(s)
                if (line.lstrip("\t") if strip else line) == delimiter:
                    break


class Parser:
    def __init__(self, cwd: str):
        self.cwd = cwd
        self.written: list[str] = []
        self.read: list[str] = []

    def resolve(self, word: Word, cwd: str) -> list[str]:
        path = os.path.normpath(os.path.join(cwd, os.path.expanduser(word.text)))
        if word.glob:
            matches = sorted(glob.glob(path))
            if matches:
                return matches
        return [path]

    def write(self, word: Word | None, cwd: str) -> None:
        if word is None or word.dynamic or not word.text or word.text == "-" or word.text.startswith("/dev/"):
            return
        if REMOTE.match(word.text):
            return
        self.written.extend(self.resolve(word, cwd))

    def mention(self, word: Word, cwd: str) -> None:
        """Record `word` as read if it names an existing file."""
        if word.dynamic or not word.text or "://" in word.text:
            return
        text = word.text
        if text.startswith("-"):
            if "=" not in text:
                return
            text = text.split("=", 1)[1]  # --input=path
        for path in self.resolve(word._replace(text=text), cwd):
            if os.path.isfile(path):
                self.read.append(path)

    def run(self, command: str, depth: int = 0) -> None:
        try:
            lexer = Lexer(command).run()
        except ValueError:
            self.fallback(command)
            return
        segment: list[Word | Op] = []
        for token in [*lexer.tokens, Op(";")]:
            if isinstance(token, Op) and token.text in SEPARATORS:
                if segment:
                    self.segment(segment, depth)
                segment = []
            else:
                segment.append(token)
        if depth < 3:
            for sub in lexer.subcommands:
                self.run(sub, depth + 1)

    def fallback(self, command: str) -> None:
        """Unlexable command (the shell would refuse it too): still see plain
        redirections and the files it names."""
        for m in re.finditer(r"(?<![<&0-9])[0-9]*>>?\|?\s*([^\s;&|<>()'\"]+)", command):
            self.write(Word(m.group(1), False, "$" in m.group(1)), self.cwd)
        words = re.findall(r"[^\s;&|<>()'\"]+", command)
        if any(os.path.basename(w) in READERS for w in words):
            for text in words:
                self.mention(Word(text, False, "$" in text), self.cwd)

    def segment(self, tokens: list[Word | Op], depth: int) -> None:
        cwd = self.cwd
        words: list[Word] = []
        inputs: list[Word] = []
        i = 0
        while i < len(tokens):
            t = tokens[i]
            if isinstance(t, Op):
                target = tokens[i + 1] if i + 1 < len(tokens) and isinstance(tokens[i + 1], Word) else None
                i += 2 if target else 1
                if target is None:
                    continue
                # `>&2`, `<&3`, `>&-`: descriptor duplication, not a file.
                if t.text in (">&", "<&") and re.fullmatch(r"[0-9]+-?|-", target.text):
                    continue
                if ">" in t.text:
                    self.write(target, cwd)
                elif t.text != "<<<":
                    inputs.append(target)
                continue
            words.append(t)
            i += 1

        while words and (ASSIGNMENT.match(words[0].text) or words[0].text in PREFIXES):
            words.pop(0)
            while words and words[0].text.startswith("-"):  # sudo -u x, nice -n 5
                words.pop(0)
        if not words:
            return
        name, args = os.path.basename(words[0].text), words[1:]
        texts = [a.text for a in args]

        sub = next((t for t in texts if not t.startswith("-")), "")
        if name in READERS or (name == "git" and sub in GIT_READERS):
            for a in args + inputs:
                self.mention(a, cwd)

        if name == "cd":
            target = next((a for a in args if not a.text.startswith("-")), Word("~", False, False))
            if target.text != "-" and not target.dynamic:
                self.cwd = self.resolve(target, cwd)[0]
        elif name in SHELLS and "-c" in texts and depth < 3:
            k = texts.index("-c") + 1
            if k < len(args):
                self.run(args[k].text, depth + 1)
        elif name == "tee":
            for a in operands(args):
                self.write(a, cwd)
        elif name in ("sed", "gsed"):
            if any(re.match(r"^(-[a-zA-Z]*i|--in-place)", t) for t in texts):
                self.scripted(args, cwd, {"-e", "-f", "-l", "--expression", "--file"})
        elif name == "perl":
            if any(re.match(r"^-[a-zA-Z]*i", t) for t in texts):
                self.scripted(args, cwd, {"-e", "-E", "-M", "-I"})
        elif name in ("cp", "mv", "install", "ln", "rsync", "scp", "gcp", "gmv"):
            self.copy(name, args, cwd)
        elif name == "dd":
            for a in args:
                if a.text.startswith("of="):
                    self.write(a._replace(text=a.text[3:]), cwd)
        elif name == "truncate":
            for a in operands(args, {"-s", "--size", "-r", "--reference"}):
                self.write(a, cwd)

    def scripted(self, args: list[Word], cwd: str, value_opts: set[str]) -> None:
        """sed/perl: the first operand is the script unless -e/-f gave one."""
        has_script = any(a.text in value_opts or a.text.startswith(("--expression=", "--file=")) for a in args)
        files = operands(args, value_opts)
        for a in files if has_script else files[1:]:
            self.write(a, cwd)

    def copy(self, name: str, args: list[Word], cwd: str) -> None:
        ops = operands(args, {"-t", "--target-directory", "-S", "--suffix", "-m", "--mode", "-o", "-g", "-e"})
        target: Word | None = None
        for i, a in enumerate(args):
            if a.text in ("-t", "--target-directory") and i + 1 < len(args):
                target = args[i + 1]
            elif a.text.startswith("--target-directory="):
                target = a._replace(text=a.text.split("=", 1)[1])
        if target is None:
            if len(ops) < 2:
                return
            *sources, dest = ops
        else:
            sources, dest = ops, target
        if dest.dynamic or REMOTE.match(dest.text):
            return
        dest_path = self.resolve(dest, cwd)[0]
        if target is not None or dest.text.endswith("/") or os.path.isdir(dest_path):
            for s in sources:
                if REMOTE.match(s.text):
                    self.written.append(os.path.join(dest_path, os.path.basename(s.text.split(":", 1)[1].rstrip("/"))))
                    continue
                for src in self.resolve(s, cwd):
                    self.written.append(os.path.join(dest_path, os.path.basename(src.rstrip("/"))))
        else:
            self.written.append(dest_path)
        if name in ("mv", "gmv"):
            for s in sources:
                self.write(s, cwd)


def operands(args: list[Word], value_opts: set[str] = frozenset()) -> list[Word]:
    out, skip = [], False
    for a in args:
        if skip:
            skip = False
        elif a.text in value_opts:
            skip = True
        elif a.text and not a.text.startswith("-"):  # BSD `sed -i ''` passes an empty suffix
            out.append(a)
    return out


def paths(event: dict) -> list[tuple[str, str]]:
    """(kind, absolute path) pairs, kind being E, W or R (see the docstring)."""
    tool = event.get("tool_name", "")
    tool_input = event.get("tool_input") or {}
    cwd = event.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    if tool == "Bash":
        parser = Parser(cwd)
        parser.run(tool_input.get("command", ""))
        return [("W", p) for p in parser.written] + [("R", p) for p in parser.read]
    file = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
    return [("E", os.path.normpath(os.path.join(cwd, file)))] if file else []


def main() -> int:
    seen = set()
    for kind, path in paths(json.load(sys.stdin)):
        if (kind, path) not in seen:
            seen.add((kind, path))
            print(f"{kind}\t{path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
