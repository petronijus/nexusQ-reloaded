"""Tripwire: the systemd units the aports ship must not form an ordering cycle.

systemd resolves a boot-time ordering cycle by deleting a start job from it,
and says so once, in the journal, as a warning. The unit simply never starts:
nexusq-setupd in v1.9.0-rc1, and nexusq-control whenever it was ordered after
nexusqd while nexusqd was ordered after multi-user.target.

The cycle is usually not written anywhere, because a target orders itself after
every unit it wants (`WantedBy=`) unless that unit is already ordered after the
target (systemd's unit_add_default_target_dependency skips that edge, since it
would be a loop of two). So the graph below carries those implied edges, the
default `After=basic.target` of every unit that keeps DefaultDependencies, and
the handful of stock target orderings a cycle through our units can pass.
Units we do not ship (bluetooth.service, NetworkManager.service, ...) are nodes
without edges of their own: they cannot close a loop that runs through ours
unless they are ordered after one of ours, which stock units are not.
"""

import unittest
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UNIT_SUFFIXES = (".service", ".socket", ".timer", ".path", ".mount", ".target")
# systemd's own target orderings (units/*.target in systemd 262).
STOCK_AFTER = {
    "basic.target": {"sysinit.target", "sockets.target", "paths.target", "timers.target"},
    "multi-user.target": {"basic.target"},
    "graphical.target": {"multi-user.target"},
}


def unit_files() -> list[Path]:
    found = []
    for top in ("pmos", "userspace"):
        for p in (ROOT / top).rglob("*"):
            if p.suffix in UNIT_SUFFIXES and p.is_file() and "tests" not in p.parts:
                found.append(p)
    return found


def parse(path: Path) -> dict[str, dict[str, list[str]]]:
    """Section -> key -> every whitespace-separated value, across repeated keys."""
    out: dict[str, dict[str, list[str]]] = defaultdict(lambda: defaultdict(list))
    section = None
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line[0] in "#;":
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        if section and "=" in line:
            key, value = line.split("=", 1)
            out[section][key.strip()] += value.split()
    return out


def ordering_graph(units: dict[str, dict]) -> dict[str, set[str]]:
    """unit -> the units it starts after."""
    after: dict[str, set[str]] = defaultdict(set)
    for name, deps in STOCK_AFTER.items():
        after[name] |= deps
    for name, u in units.items():
        after[name] |= set(u["Unit"]["After"])
        for other in u["Unit"]["Before"]:
            after[other].add(name)
        default_deps = (u["Unit"]["DefaultDependencies"] or ["yes"])[-1].lower() not in ("no", "false", "0")
        if default_deps and name.endswith(".service"):
            after[name].add("basic.target")
        elif default_deps and name.endswith((".socket", ".timer", ".path")):
            after[name].add("sysinit.target")  # these run before basic.target
    for name, u in units.items():
        for target in u["Install"]["WantedBy"] + u["Install"]["RequiredBy"]:
            if not target.endswith(".target"):
                continue
            # the implied edge, skipped when the unit is already ordered after the target
            if target not in after[name]:
                after[target].add(name)
    return after


def find_cycle(after: dict[str, set[str]]) -> list[str] | None:
    white, grey, black = 0, 1, 2
    colour: dict[str, int] = defaultdict(int)
    stack: list[str] = []

    def visit(n: str) -> list[str] | None:
        colour[n] = grey
        stack.append(n)
        for m in sorted(after.get(n, ())):
            if colour[m] == grey:
                return stack[stack.index(m) :] + [m]
            if colour[m] == white:
                found = visit(m)
                if found:
                    return found
        stack.pop()
        colour[n] = black
        return None

    for n in sorted(after):
        if colour[n] == white:
            found = visit(n)
            if found:
                return found
    return None


class UnitOrdering(unittest.TestCase):
    def setUp(self):
        self.units = {p.name: parse(p) for p in unit_files()}

    def test_there_are_units_to_check(self):
        self.assertIn("nexusqd.service", self.units)
        self.assertIn("nexusq-control.service", self.units)

    def test_no_ordering_cycle(self):
        cycle = find_cycle(ordering_graph(self.units))
        self.assertIsNone(cycle, "boot ordering cycle (each starts after the next): " + " -> ".join(cycle or []))

    def test_no_cycle_next_to_an_older_nexusqd(self):
        # An OTA interrupted halfway (apk killed on its timeout, power cut) can
        # leave these peer units next to nexusqd r24 or older, which was ordered
        # After=multi-user.target with no Before=. The peers' ordering on nexusqd
        # must therefore live in nexusqd's unit, never in theirs.
        units = dict(self.units)
        old = parse(self.unit_path("nexusqd.service"))
        old["Unit"]["After"] = ["multi-user.target", "systemd-modules-load.service"]
        old["Unit"]["Before"] = []
        units["nexusqd.service"] = old
        cycle = find_cycle(ordering_graph(units))
        self.assertIsNone(cycle, "cycle with an older nexusqd: " + " -> ".join(cycle or []))

    def unit_path(self, name: str) -> Path:
        return next(p for p in unit_files() if p.name == name)

    def test_the_implied_target_edge_is_modelled(self):
        # The v1.9.0-rc1 shape: a peer ordered after nexusqd while nexusqd is
        # ordered after the target that wants them both. Nothing in it names a
        # loop; the loop is the target's implied After= on the peer.
        units = {
            "a.service": {"Unit": {"After": ["multi-user.target"]}, "Install": {"WantedBy": ["multi-user.target"]}},
            "b.service": {"Unit": {"After": ["a.service"]}, "Install": {"WantedBy": ["multi-user.target"]}},
        }
        for u in units.values():
            u["Unit"] = defaultdict(list, u["Unit"])
            u["Install"] = defaultdict(list, u["Install"])
        cycle = find_cycle(ordering_graph(units))
        self.assertIsNotNone(cycle)
        self.assertEqual(set(cycle), {"multi-user.target", "a.service", "b.service"})
        # and the two-unit loop systemd itself skips is not reported
        del units["b.service"]
        self.assertIsNone(find_cycle(ordering_graph(units)))


if __name__ == "__main__":
    unittest.main()
