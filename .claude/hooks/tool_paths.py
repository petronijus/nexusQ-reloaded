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
                      `--env-file .env`) is not reading it. A recursive
                      search or dump of a directory (`grep -r`, `rg`, `ag`,
                      `git grep`, `find … -exec cat`, `tar c … | xxd`) is
                      reported as every file it would reach — for `rg`,
                      `ag` and `git grep` minus what .gitignore excludes and,
                      for `rg`/`ag`, minus hidden files, as they do.

Edit, Write and NotebookEdit name their file directly. For Bash the command
is lexed the way the shell splits it (quotes, escapes, line continuations,
heredocs, `$(…)` and backticks, unquoted globs) and read for the ways agents
actually write files: redirections (`>`, `>>`, `&>`, `>|`), `tee`,
`sed -i`, `perl -i`, `cp`/`mv`/`install`/`ln`/`rsync`, `dd of=`,
`truncate`, nested `bash -c '…'` / `env -S '…'`, and `cd` between commands
(and `env -C` / `sudo -D`). Wrappers are unwrapped with their options
(`sudo -u root cat .env` reads .env). Remote targets (`host:/path` for rsync
and scp) are not local files and are skipped. A directory walk skips .git
and dependency/build trees (node_modules, .venv, …) and stops at MAX_WALK
files.

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
import subprocess
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
# Words that run the rest of the line as a command, with the options of each
# that take a value (the next word, unless written `--opt=value`). Without
# the table `sudo -u root cat .env` read as the program `root` (v5).
WRAPPERS = {
    "sudo": {"-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U", "-T", "-R", "--user", "--group",
             "--close-from", "--chdir", "--host", "--prompt", "--role", "--type", "--other-user",
             "--command-timeout", "--chroot"},
    "doas": {"-u", "-C"},
    "env": {"-u", "--unset", "-C", "--chdir", "-S", "--split-string"},
    "nice": {"-n", "--adjustment"},
    "ionice": {"-c", "-n", "-p", "-P", "-u", "--class", "--classdata"},
    "timeout": {"-s", "--signal", "-k", "--kill-after"},
    "stdbuf": {"-i", "-o", "-e", "--input", "--output", "--error"},
    "time": {"-f", "-o", "--format", "--output"},
    "exec": {"-a"},
    "command": set(),
    "builtin": set(),
    "nohup": set(),
}  # fmt: skip
# Options of those wrappers that change the directory the command runs in.
CHDIR_OPTS = {"-C", "--chdir", "-D"}
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
    "dtc",
    "fdtdump",
    "fdtget",
    "plutil",
    "iconv",
    "tr",
}
# `git <subcommand>` that prints file contents.
GIT_READERS = {"show", "diff", "blame", "log", "grep", "cat-file"}
# Searchers that take a pattern first, then paths (the working directory when
# none is given), and read directories recursively: `recursive` says when,
# `values` are the options that take the next word.
GREP_VALUES = {"-e", "-f", "-A", "-B", "-C", "-m", "-d", "-D", "--regexp", "--file", "--max-count",
               "--context", "--after-context", "--before-context", "--include", "--exclude",
               "--exclude-dir", "--exclude-from", "--label", "--directories", "--devices", "--color",
               "--colour", "--binary-files"}  # fmt: skip
RG_VALUES = {"-e", "-f", "-g", "-t", "-T", "-A", "-B", "-C", "-m", "-M", "-j", "-r", "-E", "-d",
             "--regexp", "--file", "--glob", "--iglob", "--type", "--type-not", "--type-add",
             "--max-count", "--max-columns", "--threads", "--context", "--after-context",
             "--before-context", "--replace", "--pre", "--pre-glob", "--sort", "--sortr",
             "--encoding", "--color", "--colors", "--max-depth", "--ignore-file", "--path-separator",
             "--max-filesize", "--dfa-size-limit", "--regex-size-limit", "--engine"}  # fmt: skip
AG_VALUES = {"-A", "-B", "-C", "-G", "-g", "-m", "-p", "--ignore", "--ignore-dir", "--depth",
             "--path-to-ignore", "--file-search-regex", "--max-count", "--context", "--after",
             "--before", "--pager", "--workers"}  # fmt: skip
ACK_VALUES = {"-A", "-B", "-C", "-m", "-g", "--type", "--ignore-dir", "--ignore-file",
              "--max-count", "--context", "--after-context", "--before-context", "--match",
              "--output", "--pager"}  # fmt: skip
TAR_VALUES = {"-f", "--file", "-C", "--directory", "-T", "--files-from", "-X", "--exclude-from",
              "-b", "--blocking-factor", "-H", "--format", "-I", "--use-compress-program",
              "--exclude"}  # fmt: skip
# Trees a directory walk never enters: a secret there is improbable, and a
# walk through them would cost more than the hook's budget.
SKIP_DIRS = {".git", "node_modules", ".venv", "venv", "__pycache__", ".dart_tool", ".gradle",
             "Pods", ".pnpm-store", ".next", ".turbo", ".cache", "target"}  # fmt: skip
MAX_WALK = 50000
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

        words, cwd = self.unwrap(words, cwd, depth)
        if not words:
            return
        name, args = os.path.basename(words[0].text), words[1:]
        texts = [a.text for a in args]

        sub = next((t for t in texts if not t.startswith("-")), "")
        if self.searched(name, args, sub, cwd):
            for a in inputs:
                self.mention(a, cwd)
        elif name in READERS or (name == "git" and sub in GIT_READERS):
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

    def unwrap(self, words: list[Word], cwd: str, depth: int) -> tuple[list[Word], str]:
        """Strip assignments and wrappers (with their options) off a command.

        `env -S '…'` runs its string as a command; `env -C dir`, `sudo -D dir`
        move the command's working directory.
        """
        while words:
            if ASSIGNMENT.match(words[0].text):
                words = words[1:]
                continue
            name = os.path.basename(words[0].text)
            if name not in WRAPPERS:
                break
            values, words = WRAPPERS[name], words[1:]
            duration = name == "timeout"  # `timeout 5 cmd`: the first operand is not the command
            while words:
                t = words[0].text
                if t == "--":
                    words = words[1:]
                    break
                if t.startswith("--"):
                    opt, eq, val = t.partition("=")
                    words = words[1:]
                    if opt in values:
                        if eq:
                            cwd = self.wrapper_option(name, opt, Word(val, False, "$" in val), cwd, depth)
                        elif words:
                            cwd = self.wrapper_option(name, opt, words[0], cwd, depth)
                            words = words[1:]
                    continue
                if t.startswith("-") and len(t) > 1:
                    words = words[1:]
                    for k, ch in enumerate(t[1:]):
                        if "-" + ch in values:  # the rest of the cluster, or the next word, is its value
                            rest = t[k + 2 :]
                            if rest:
                                cwd = self.wrapper_option(name, "-" + ch, Word(rest, False, "$" in rest), cwd, depth)
                            elif words:
                                cwd = self.wrapper_option(name, "-" + ch, words[0], cwd, depth)
                                words = words[1:]
                            break
                    continue
                if name == "env" and ASSIGNMENT.match(t):
                    words = words[1:]
                    continue
                if duration:
                    duration, words = False, words[1:]
                    continue
                break
        return words, cwd

    def wrapper_option(self, name: str, opt: str, value: Word, cwd: str, depth: int) -> str:
        """Act on a wrapper option's value; returns the command's working directory."""
        if value.dynamic:
            return cwd
        if opt in {"env": ("-C", "--chdir"), "sudo": ("-D", "--chdir")}.get(name, ()):
            return self.resolve(value, cwd)[0]
        if opt in ("-S", "--split-string") and depth < 3:
            self.run(value.text, depth + 1)
        return cwd

    def searched(self, name: str, args: list[Word], sub: str, cwd: str) -> bool:
        """Record what a recursive search or dump reads; False if it is none."""
        texts = [a.text for a in args]
        shorts = "".join(t[1:] for t in texts if re.match(r"^-[A-Za-z.]+$", t))
        if name in ("grep", "egrep", "fgrep"):
            if not ({"-r", "-R", "--recursive", "--dereference-recursive"} & set(texts) or set("rR") & set(shorts)):
                return False
            self.search(args, cwd, GREP_VALUES, ignore=False, hidden=True)
        elif name == "rg":
            u = shorts.count("u") + (2 if "--unrestricted" in texts else 0)
            ignore = u == 0 and not any(t.startswith("--no-ignore") for t in texts)
            hidden = u >= 2 or "--hidden" in texts or "." in shorts
            self.search(args, cwd, RG_VALUES, ignore, hidden, patternless="--files" in texts)
        elif name == "ag":
            unrestricted = "u" in shorts or "--unrestricted" in texts
            self.search(args, cwd, AG_VALUES, ignore=not unrestricted, hidden=unrestricted or "--hidden" in texts)
        elif name == "ack":
            self.search(args, cwd, ACK_VALUES, ignore=False, hidden=True)
        elif name == "git" and sub == "grep":
            rest = args[texts.index("grep") + 1 :]
            no_index = "--no-index" in texts
            self.search(rest, cwd, GREP_VALUES, ignore=not no_index, hidden=True)
        elif name == "find":
            execs = [i for i, t in enumerate(texts) if t in ("-exec", "-execdir", "-ok", "-okdir")]
            if not any(i + 1 < len(texts) and os.path.basename(texts[i + 1]) in READERS for i in execs):
                return False
            starts = []
            for a in args:
                if a.text.startswith(("-", "(", "!")):
                    break
                starts.append(a)
            for a in starts or [Word(".", False, False)]:
                self.reach(a, cwd, ignore=False, hidden=True)
        elif name == "tar":
            return self.tar(args, cwd)
        elif name == "zip":
            ops = operands(args, {"-b", "-n", "-t", "-tt", "-x", "-i", "-P", "-Z"})
            if not ops or ops[0].text != "-":  # only `zip - …` prints the archive
                return False
            for a in ops[1:]:
                self.reach(a, cwd, ignore=False, hidden=True)
        else:
            return False
        return True

    def search(
        self, args: list[Word], cwd: str, values: set[str], ignore: bool, hidden: bool, patternless: bool = False
    ) -> None:
        """A searcher: its pattern (unless -e/-f gave it) is not a path; no path means `.`."""
        explicit, skip, dashdash, ops = patternless, False, False, []
        for a in args:
            t = a.text
            if skip:
                skip = False
            elif dashdash or not t.startswith("-") or t == "-":
                ops.append(a)
            elif t == "--":
                dashdash = True
            elif t.startswith("--"):
                opt, eq, _ = t.partition("=")
                explicit = explicit or opt in ("--regexp", "--file")
                skip = opt in values and not eq
            else:
                for k, ch in enumerate(t[1:]):
                    if "-" + ch in values:
                        explicit = explicit or ch in "ef"
                        skip = k == len(t) - 2
                        break
        if not explicit and ops:
            ops = ops[1:]
        for a in ops or [Word(".", False, False)]:
            self.reach(a, cwd, ignore, hidden)

    def tar(self, args: list[Word], cwd: str) -> bool:
        """`tar c` writing the archive to stdout prints every file it packs."""
        texts = [a.text for a in args]
        first = texts[0] if texts else ""
        bundled = bool(re.fullmatch(r"[A-Za-z]+", first))
        letters = first if bundled else "".join(t[1:] for t in texts if re.match(r"^-[A-Za-z]+$", t))
        if "c" not in letters and "--create" not in texts:
            return False
        archive, base, members, skip = None, cwd, [], None
        rest = args[1:] if bundled else args
        if bundled and "f" in first and rest:
            archive, rest = rest[0].text, rest[1:]
        for a in rest:
            t = a.text
            if skip:
                if skip in ("-f", "--file"):
                    archive = t
                elif skip in ("-C", "--directory"):
                    base = self.resolve(a, base)[0]
                skip = None
            elif t.startswith("--"):
                opt, eq, val = t.partition("=")
                if opt == "--file" and eq:
                    archive = val
                elif opt == "--directory" and eq:
                    base = self.resolve(Word(val, False, False), base)[0]
                elif opt in TAR_VALUES and not eq:
                    skip = opt
            elif t.startswith("-") and len(t) > 1:
                last = "-" + t[-1]
                if last in TAR_VALUES:
                    skip = last
            else:
                members.append((a, base))
        if archive not in (None, "-"):
            return False
        for a, b in members:
            self.reach(a, b, ignore=False, hidden=True)
        return True

    def reach(self, word: Word, cwd: str, ignore: bool, hidden: bool) -> None:
        """A path a recursive reader is given: the file itself, or every file under it."""
        if word.dynamic or not word.text:
            return
        for path in self.resolve(word, cwd):
            if os.path.isfile(path):
                self.read.append(path)
            elif os.path.isdir(path):
                self.read.extend(walk(path, ignore, hidden))

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


def walk(root: str, ignore: bool, hidden: bool) -> list[str]:
    """The files a recursive reader reaches under `root`.

    ignore: the reader honours .gitignore (rg, ag, git grep): ask git, which
    knows every ignore file; outside a work tree nothing is ignored.
    hidden: whether it reads dot-files (rg and ag skip them by default).
    """
    found: list[str] = []
    if ignore:
        try:
            out = subprocess.run(
                ["git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                capture_output=True,
                timeout=5,
            )
        except (OSError, subprocess.TimeoutExpired):
            out = None
        if out is not None and out.returncode == 0:
            for rel in out.stdout.decode("utf-8", "surrogateescape").split("\0"):
                if not rel or (not hidden and any(part.startswith(".") for part in rel.split("/"))):
                    continue
                path = os.path.join(root, rel)
                if os.path.isfile(path):
                    found.append(os.path.normpath(path))
                    if len(found) >= MAX_WALK:
                        break
            return found
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and (hidden or not d.startswith("."))]
        for f in filenames:
            if hidden or not f.startswith("."):
                found.append(os.path.join(dirpath, f))
                if len(found) >= MAX_WALK:
                    return found
    return found


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
