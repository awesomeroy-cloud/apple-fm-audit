#!/usr/bin/env python3
import unittest

from apple_fm_audit.pcc import (
    choose_model,
    is_network_failure,
    is_pcc_model,
    pcc_availability,
    set_json_model,
)


class PccModelIdTest(unittest.TestCase):
    def test_aliases(self):
        self.assertTrue(is_pcc_model("pcc"))
        self.assertTrue(is_pcc_model("PrivateCloudCompute"))
        self.assertFalse(is_pcc_model("system"))


class PccAvailabilityTest(unittest.TestCase):
    def test_missing_from_health(self):
        out = pcc_availability(
            {"reachable": True, "models": [{"name": "system", "available": True}]}
        )
        self.assertEqual(out["state"], "unsupported")

    def test_available(self):
        out = pcc_availability(
            {
                "reachable": True,
                "models": [
                    {"name": "system", "available": True},
                    {"name": "pcc", "available": True},
                ],
            }
        )
        self.assertEqual(out["state"], "available")

    def test_device_not_eligible(self):
        out = pcc_availability(
            {
                "reachable": True,
                "models": [
                    {
                        "name": "pcc",
                        "available": False,
                        "reason": "deviceNotEligible",
                    }
                ],
            }
        )
        self.assertEqual(out["state"], "deviceNotEligible")

    def test_system_not_ready(self):
        out = pcc_availability(
            {
                "reachable": True,
                "models": [
                    {
                        "name": "pcc",
                        "available": False,
                        "reason": "PCC isn't ready to serve requests (systemNotReady)",
                    }
                ],
            }
        )
        self.assertEqual(out["state"], "systemNotReady")


class ChooseModelTest(unittest.TestCase):
    def test_system_unchanged(self):
        model, note = choose_model(
            "system",
            {"reachable": True, "models": [{"name": "system", "available": True}]},
        )
        self.assertEqual(model, "system")
        self.assertIsNone(note)

    def test_pcc_falls_back_when_unsupported(self):
        model, note = choose_model(
            "pcc",
            {"reachable": True, "models": [{"name": "system", "available": True}]},
        )
        self.assertEqual(model, "system")
        self.assertIn("unsupported", note or "")

    def test_pcc_kept_when_available(self):
        model, note = choose_model(
            "pcc",
            {
                "reachable": True,
                "models": [{"name": "pcc", "available": True}],
            },
        )
        self.assertEqual(model, "pcc")
        self.assertIsNone(note)


class NetworkFailureTest(unittest.TestCase):
    def test_network_error_body(self):
        self.assertTrue(
            is_network_failure(
                503,
                '{"error":{"message":"NetworkFailureError: connection unavailable"}}',
                None,
            )
        )

    def test_unknown_model_is_not_network(self):
        self.assertFalse(
            is_network_failure(
                400,
                '{"error":{"message":"Unknown model \'pcc\'. Available models: system"}}',
                None,
            )
        )


class SetModelTest(unittest.TestCase):
    def test_rewrites_model(self):
        out = set_json_model(b'{"model":"pcc","messages":[]}', "system")
        self.assertEqual(out.decode(), '{"model": "system", "messages": []}')


if __name__ == "__main__":
    unittest.main()
