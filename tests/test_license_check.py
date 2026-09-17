#!/usr/bin/env python3
import unittest

from apple_fm_audit.license_check import parse_status


class ParseStatusTest(unittest.TestCase):
    def test_agreed(self):
        self.assertTrue(
            parse_status(
                "Agreed to license FM1 version 1.0 on Sep 17, 2026 at 01:40.\n",
                0,
            )
        )

    def test_not_agreed_message(self):
        self.assertFalse(
            parse_status(
                "YOU HAVE NOT AGREED TO THE APPLE FOUNDATION MODELS CLI "
                "LEGAL NOTICE & TERMS.\n",
                1,
            )
        )

    def test_nonzero_without_agreed(self):
        self.assertFalse(parse_status("Error: Unknown command\n", 1))

    def test_empty(self):
        self.assertFalse(parse_status("", 0))


if __name__ == "__main__":
    unittest.main()
