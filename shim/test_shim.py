"""Unit tests for the shim's telemetry->vehicle_data translation.

Run:  python3 -m unittest discover -s shim -v
      (or ./scripts/test.sh, which runs them in the container image)

These cover the translation layer, which is where every bug so far has lived.
Each class notes the real-world failure it guards against, because these are
regression tests before they are anything else -- the failures were silent
(wrong values on a dashboard), not crashes.
"""
import os
import unittest

os.environ["SHIM_NO_START"] = "1"          # don't spawn the ZMQ subscriber
os.environ.setdefault("DATA_DIR", "/tmp/shim-test-data")
os.environ.setdefault("VIN", "TESTVIN0000000000")

import shim  # noqa: E402


class TestUnwrap(unittest.TestCase):
    """Telemetry values arrive type-wrapped: {"doubleValue": 1.5}."""

    def test_typed_values(self):
        self.assertEqual(shim.unwrap({"doubleValue": 1.5}), 1.5)
        self.assertEqual(shim.unwrap({"intValue": 7}), 7)
        self.assertEqual(shim.unwrap({"stringValue": "x"}), "x")
        self.assertEqual(shim.unwrap({"booleanValue": True}), True)

    def test_location_is_returned_whole(self):
        loc = {"latitude": 1.0, "longitude": 2.0}
        self.assertEqual(shim.unwrap({"locationValue": loc}), loc)

    def test_invalid_becomes_none(self):
        self.assertIsNone(shim.unwrap({"invalid": True}))

    def test_plain_values_pass_through(self):
        self.assertEqual(shim.unwrap(5), 5)
        self.assertEqual(shim.unwrap("plain"), "plain")
        self.assertIsNone(shim.unwrap(None))


class TestEnumTail(unittest.TestCase):
    """Enums look like '<Field>State<Value>'; we want just <Value>."""

    def test_strips_state_prefix(self):
        self.assertEqual(shim.enum_tail("SentryModeStateArmed"), "Armed")
        self.assertEqual(shim.enum_tail("WindowStateClosed"), "Closed")
        self.assertEqual(shim.enum_tail("ShiftStateP"), "P")
        self.assertEqual(shim.enum_tail("DetailedChargeStateCharging"), "Charging")

    def test_passthrough_and_none(self):
        self.assertEqual(shim.enum_tail("Charging"), "Charging")
        self.assertEqual(shim.enum_tail(None), "")


class TestTruthy(unittest.TestCase):
    """REGRESSION: enum strings used to fall through to False.

    Twice. First SentryMode reported False while armed; then, after an exact
    word list was added, 'Opened' (past tense) still reported windows closed.
    """

    def test_windows_open_are_true(self):
        self.assertTrue(shim.truthy("WindowStateOpened"))        # the 2nd bug
        self.assertTrue(shim.truthy("WindowStatePartiallyOpen"))
        self.assertTrue(shim.truthy("WindowStateOpen"))

    def test_windows_closed_are_false(self):
        self.assertFalse(shim.truthy("WindowStateClosed"))

    def test_hvac(self):
        self.assertTrue(shim.truthy("HvacPowerStateOn"))
        self.assertFalse(shim.truthy("HvacPowerStateOff"))

    def test_plain_words(self):
        for v in ("true", "1", "on", "yes", "True"):
            self.assertTrue(shim.truthy(v), v)
        for v in ("false", "0", "off", "no", ""):
            self.assertFalse(shim.truthy(v), v)

    def test_bools_and_none(self):
        self.assertTrue(shim.truthy(True))
        self.assertFalse(shim.truthy(False))
        self.assertFalse(shim.truthy(None))


class TestSentry(unittest.TestCase):
    """REGRESSION: sentry_mode reported False while the car was armed.

    Sentry is a multi-state enum but the Fleet API exposes a boolean; anything
    that is not Off means the feature is on.
    """

    def test_active_states_are_on(self):
        for s in ("Armed", "Aware", "Idle", "Panic", "Quiet"):
            self.assertTrue(shim.sentry_on("SentryModeState" + s), s)

    def test_off_and_unknown_are_off(self):
        self.assertFalse(shim.sentry_on("SentryModeStateOff"))
        self.assertFalse(shim.sentry_on("SentryModeStateUnknown"))
        self.assertFalse(shim.sentry_on(None))

    def test_bool_passthrough(self):
        self.assertTrue(shim.sentry_on(True))
        self.assertFalse(shim.sentry_on(False))


class TestShiftState(unittest.TestCase):
    def test_valid_gears(self):
        for g in ("P", "D", "R", "N"):
            self.assertEqual(shim.as_shift("ShiftState" + g), g)

    def test_invalid_is_none(self):
        self.assertIsNone(shim.as_shift(None))
        self.assertIsNone(shim.as_shift("ShiftStateInvalid"))


class TestToInt(unittest.TestCase):
    """REGRESSION: TeslaMate validates these as integers and silently DROPPED
    the whole record when telemetry sent floats like 16.00000023841858."""

    def test_rounds_float_noise(self):
        self.assertEqual(shim.to_int(16.00000023841858), 16)
        self.assertEqual(shim.to_int(241.16399869322777), 241)
        self.assertEqual(shim.to_int(78.9802289281998), 79)

    def test_passthrough_and_bad_input(self):
        self.assertEqual(shim.to_int(5), 5)
        self.assertIsNone(shim.to_int(None))
        self.assertIsNone(shim.to_int("abc"))


class TestWindowHelper(unittest.TestCase):
    def test_maps_to_int_flags(self):
        self.assertEqual(shim.window("WindowStateOpened"), 1)
        self.assertEqual(shim.window("WindowStateClosed"), 0)


class TestSignalMapping(unittest.TestCase):
    """End-to-end: raw signal -> the vehicle_data document TeslaMate reads."""

    def setUp(self):
        shim.DOC = shim.blank_doc()
        shim.RAW.clear()

    def apply(self, key, value):
        shim.RAW[key] = value
        shim.apply_signal(key, value)
        shim.apply_composites()

    def test_battery_is_int(self):
        self.apply("Soc", 78.98)
        cs = shim.DOC["charge_state"]
        self.assertEqual(cs["battery_level"], 79)
        self.assertEqual(cs["usable_battery_level"], 79)

    def test_sentry_and_lock(self):
        self.apply("SentryMode", "SentryModeStateArmed")
        self.apply("Locked", True)
        self.assertTrue(shim.DOC["vehicle_state"]["sentry_mode"])
        self.assertTrue(shim.DOC["vehicle_state"]["locked"])

    def test_sentry_mapping_uses_state_semantics_not_word_matching(self):
        """Guards the MAP wiring, not just the helper.

        truthy() accepts 'Armed' by coincidence (it is in the true-word list),
        so testing only Armed cannot tell sentry_on() and truthy() apart. The
        non-Off states that truthy() does NOT know are what pin the wiring.
        """
        for state in ("Aware", "Idle", "Panic"):
            shim.DOC = shim.blank_doc()
            shim.RAW.clear()
            self.apply("SentryMode", "SentryModeState" + state)
            self.assertTrue(
                shim.DOC["vehicle_state"]["sentry_mode"],
                "sentry_mode must be True for state %s" % state,
            )

    def test_charging_state_enum_is_stripped(self):
        self.apply("DetailedChargeState", "DetailedChargeStateCharging")
        self.assertEqual(shim.DOC["charge_state"]["charging_state"], "Charging")

    def test_no_unit_conversion(self):
        """REGRESSION: an early version divided km->miles. Telemetry already
        matches the Fleet API (miles, Celsius); converting showed 169 mi where
        the true value was 273."""
        self.apply("RatedRange", 273.36)
        self.apply("Odometer", 4183.86)
        self.apply("OutsideTemp", 27.0)
        self.assertAlmostEqual(shim.DOC["charge_state"]["battery_range"], 273.36)
        self.assertAlmostEqual(shim.DOC["vehicle_state"]["odometer"], 4183.86)
        self.assertAlmostEqual(shim.DOC["climate_state"]["outside_temp"], 27.0)

    def test_location_populates_both_field_pairs(self):
        self.apply("Location", {"latitude": 34.018, "longitude": -84.607})
        ds = shim.DOC["drive_state"]
        self.assertAlmostEqual(ds["latitude"], 34.018)
        self.assertAlmostEqual(ds["longitude"], -84.607)
        self.assertAlmostEqual(ds["native_latitude"], 34.018)
        self.assertAlmostEqual(ds["native_longitude"], -84.607)

    def test_doors_dict_expands_to_flat_fields(self):
        self.apply("DoorState", {"DriverFront": True, "PassengerRear": False})
        vs = shim.DOC["vehicle_state"]
        self.assertEqual(vs["df"], 1)
        self.assertEqual(vs["pr"], 0)

    def test_charger_power_prefers_the_live_source(self):
        self.apply("ACChargingPower", 0)
        self.apply("DCChargingPower", 48.6)
        self.assertEqual(shim.DOC["charge_state"]["charger_power"], 49)

    def test_unknown_signal_is_ignored(self):
        shim.apply_signal("SomeFutureSignal", "whatever")  # must not raise


class TestStreamRow(unittest.TestCase):
    """TeslaMate parses the stream as a positional CSV. Wrong order or a
    wrong column count corrupts every field silently."""

    def setUp(self):
        shim.DOC = shim.blank_doc()
        shim.RAW.clear()

    def test_column_order_is_the_contract(self):
        self.assertEqual(
            shim.STREAM_COLUMNS,
            ("speed", "odometer", "soc", "elevation", "est_heading",
             "est_lat", "est_lng", "power", "shift_state", "range",
             "est_range", "heading"),
        )

    def test_row_is_timestamp_plus_every_column(self):
        cells = shim.stream_row().split(",")
        self.assertEqual(len(cells), len(shim.STREAM_COLUMNS) + 1)
        self.assertTrue(cells[0].isdigit(), "first cell must be a ms timestamp")

    def test_values_land_in_the_right_positions(self):
        shim.DOC["charge_state"]["battery_level"] = 79
        shim.DOC["vehicle_state"]["odometer"] = 4183.86
        shim.DOC["drive_state"]["speed"] = 55
        shim.DOC["drive_state"]["shift_state"] = "D"
        cells = shim.stream_row().split(",")
        idx = {c: i + 1 for i, c in enumerate(shim.STREAM_COLUMNS)}
        self.assertEqual(cells[idx["soc"]], "79")
        self.assertEqual(cells[idx["odometer"]], "4183.86")
        self.assertEqual(cells[idx["speed"]], "55")
        self.assertEqual(cells[idx["shift_state"]], "D")

    def test_missing_values_are_empty_not_none(self):
        """'None' as a string would be parsed as data; empty means nil."""
        cells = shim.stream_row().split(",")
        idx = {c: i + 1 for i, c in enumerate(shim.STREAM_COLUMNS)}
        self.assertEqual(cells[idx["elevation"]], "")
        self.assertNotIn("None", cells)


class TestApiShape(unittest.TestCase):
    """TeslaMate needs these keys present or it errors on the response."""

    def setUp(self):
        shim.DOC = shim.blank_doc()
        shim.RAW.clear()

    def test_snapshot_has_all_sections(self):
        snap = shim.snapshot()
        for section in ("charge_state", "climate_state", "drive_state",
                        "vehicle_state", "vehicle_config", "gui_settings"):
            self.assertIn(section, snap)
            self.assertIn("timestamp", snap[section])

    def test_summary_always_has_a_display_name(self):
        self.assertTrue(shim.summary()["display_name"])

    def test_offline_when_no_signal_seen(self):
        shim.LAST_SIGNAL = 0.0
        self.assertFalse(shim.online())


if __name__ == "__main__":
    unittest.main(verbosity=2)
