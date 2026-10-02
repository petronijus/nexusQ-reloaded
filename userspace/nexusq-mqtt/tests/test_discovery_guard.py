"""The unit keeps its Home Assistant discovery configs its own (nexusq-mqtt r17).

On 2026-10-01 the cottage broker's bridge replayed 19 stale configs carrying
the Prague Q's node_id into the home broker, and HA showed the cottage's frozen
numbers under the Prague Q's name until someone looked. The guard answers a
foreign config on our node_id: ours again where we publish one, cleared where
we do not, and our own echo with nothing.
"""

import importlib.machinery
import importlib.util
import json
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-mqtt")


def load_daemon():
    spec = importlib.util.spec_from_loader("nexusq_mqtt", importlib.machinery.SourceFileLoader("nexusq_mqtt", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MOD = load_daemon()
NODE = "nexusq_f88fca2048e1"
OURS = json.dumps({"name": "Die temperature", "state_topic": f"nexusq/{NODE}/health/state"})
STALE = json.dumps({"name": "Die temperature", "state_topic": "nexusq-sumperak/health/state"})
TEMP = f"homeassistant/sensor/{NODE}/temp/config"


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


class TestGuard(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.g = MOD.DiscoveryGuard("homeassistant", NODE, clock=self.clock)
        self.g.record(TEMP, OURS)

    def test_the_filter_is_exactly_our_node(self):
        self.assertEqual(self.g.filter, f"homeassistant/+/{NODE}/+/config")
        self.assertTrue(self.g.mine(TEMP))
        self.assertFalse(self.g.mine("homeassistant/sensor/nexusq_f88fca051f11/temp/config"))
        self.assertFalse(self.g.mine(f"homeassistant/sensor/{NODE}/temp/state"))
        self.assertFalse(self.g.mine(f"nexusq/{NODE}/health/state"))

    def test_our_own_echo_is_left_alone(self):
        self.assertIsNone(self.g.observe(TEMP, OURS.encode()))

    def test_a_foreign_version_of_ours_is_answered_with_ours(self):
        self.assertEqual(self.g.observe(TEMP, STALE.encode()), (TEMP, OURS))

    def test_a_config_we_never_published_is_cleared(self):
        topic = f"homeassistant/binary_sensor/{NODE}/led/config"
        self.assertEqual(self.g.observe(topic, STALE.encode()), (topic, ""))

    def test_a_config_we_retracted_is_cleared_again(self):
        topic = f"homeassistant/sensor/{NODE}/volume/config"
        self.g.record(topic, "")
        self.assertEqual(self.g.observe(topic, STALE.encode()), (topic, ""))
        self.clock.t += MOD.DiscoveryGuard.HOLDOFF_S
        self.assertIsNone(self.g.observe(topic, b""), "the empty retained it leaves is ours")

    def test_a_fight_is_answered_at_most_once_per_holdoff(self):
        self.assertIsNotNone(self.g.observe(TEMP, STALE.encode()))
        self.clock.t += 5
        self.assertIsNone(self.g.observe(TEMP, STALE.encode()))
        self.clock.t += MOD.DiscoveryGuard.HOLDOFF_S
        self.assertIsNotNone(self.g.observe(TEMP, STALE.encode()))

    def test_a_write_inside_the_holdoff_is_answered_after_it(self):
        # the Prague Q, 2026-10-02: a stale config, then its removal 8 s later
        self.assertEqual(self.g.observe(TEMP, STALE.encode()), (TEMP, OURS))
        self.clock.t += 8
        self.assertIsNone(self.g.observe(TEMP, b""))
        self.assertEqual(self.g.due(), [])
        self.clock.t += MOD.DiscoveryGuard.HOLDOFF_S
        self.assertEqual(self.g.due(), [(TEMP, OURS)])
        self.assertEqual(self.g.due(), [], "answered once")

    def test_a_deferred_write_undone_meanwhile_needs_nothing(self):
        self.g.observe(TEMP, STALE.encode())
        self.clock.t += 8
        self.g.observe(TEMP, STALE.encode())
        self.g.observe(TEMP, OURS.encode())  # someone (us) put ours back
        self.clock.t += MOD.DiscoveryGuard.HOLDOFF_S
        self.assertEqual(self.g.due(), [])

    def fight(self):
        """A writer that puts the stale config back right after each answer:
        the times (since the first write) at which the guard answers."""
        t0, times = self.clock.t, []
        for _ in range(4 * 3600):
            fix = self.g.observe(TEMP, STALE.encode())
            for _f in ([fix] if fix else []) + self.g.due():
                times.append(round(self.clock.t - t0))
            self.clock.t += 1
        return times

    def test_answers_back_off_then_stop(self):
        self.assertEqual(self.fight(), [0, 60, 180, 420, 900, 1860])
        self.assertIn(TEMP, self.g.gave_up)

    def test_a_new_episode_is_answered_at_once(self):
        # a stale replay at each bridge reconnect, hours apart, even after the
        # guard gave up on an earlier fight
        self.fight()
        self.clock.t += MOD.DiscoveryGuard.EPISODE_GAP_S
        self.assertEqual(self.g.observe(TEMP, STALE.encode()), (TEMP, OURS))

    def test_the_fallback_node_id_is_nobodys(self):
        g = MOD.DiscoveryGuard("homeassistant", "nexusq_000000000000", clock=self.clock)
        self.assertFalse(g.enabled)
        self.assertIsNone(g.observe("homeassistant/sensor/nexusq_000000000000/temp/config", STALE.encode()))
        self.assertEqual(g.due(), [])

    def test_another_units_configs_are_none_of_our_business(self):
        other = "homeassistant/sensor/nexusq_f88fca051f11/temp/config"
        self.assertIsNone(self.g.observe(other, STALE.encode()))

    def test_only_our_node_is_recorded(self):
        self.g.record("homeassistant/sensor/nexusq_f88fca051f11/temp/config", OURS)
        self.assertEqual(set(self.g.ours), {TEMP})


class Broker:
    """A retained store: the last value per topic, delivered to every
    subscriber (the subscribers here are guards, one per unit)."""

    def __init__(self):
        self.retained = {}
        self.publishes = 0
        self.subscribers = []

    def publish(self, topic, payload):
        self.publishes += 1
        self.retained[topic] = payload
        for deliver in self.subscribers:
            deliver(topic, payload)


class TestTwoUnitsOneNodeId(unittest.TestCase):
    """Two units with one node_id (the 2026-08-29 cloned MAC) on one broker,
    each sure its own version is right. The guard must not let them fight
    forever: answers back off, then stop."""

    def test_a_fight_ends(self):
        clock = Clock()
        broker = Broker()
        units = []
        for name in ("Nexus Q", "Nexus Q Sumperak"):
            g = MOD.DiscoveryGuard("homeassistant", NODE, clock=clock)
            cfg = json.dumps({"name": "Die temperature", "device": {"name": name}})
            g.record(TEMP, cfg)
            pending = []
            broker.subscribers.append(
                lambda t, p, g=g, pending=pending: pending.extend(
                    [a for a in [g.observe(t, p.encode())] if a is not None]
                )
            )
            units.append((g, cfg, pending))
        broker.publish(TEMP, units[0][1])  # A connects
        broker.publish(TEMP, units[1][1])  # then B
        last = 0.0
        for _ in range(48 * 3600):  # two days, a tick a second
            clock.t += 1
            for g, _, pending in units:
                out, pending[:] = pending[:] + g.due(), []
                for topic, cfg in out:
                    g.record(topic, cfg)
                    broker.publish(topic, cfg)
                    last = clock.t
        # each answers at most GIVE_UP times, then one of them gives up and
        # the other's version stands
        self.assertLessEqual(broker.publishes, 2 + 2 * MOD.DiscoveryGuard.GIVE_UP)
        self.assertLess(last - 1000.0, 2 * 3600, "quiet long before the two days are over")
        self.assertTrue(any(TEMP in g.gave_up for g, _, _ in units))


if __name__ == "__main__":
    unittest.main()
