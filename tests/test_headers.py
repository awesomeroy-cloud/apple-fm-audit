#!/usr/bin/env python3
import unittest

from apple_fm_audit.headers import is_local_path, upstream_headers


class HeadersTest(unittest.TestCase):
    def test_strips_origin_referer_and_sec_fetch(self):
        out = upstream_headers(
            {
                "Content-Type": "application/json",
                "Origin": "https://example.test",
                "Referer": "https://example.test/app",
                "Sec-Fetch-Site": "cross-site",
                "Sec-Fetch-Mode": "cors",
                "Authorization": "Bearer x",
            }
        )
        keys = {k.lower() for k in out}
        self.assertNotIn("origin", keys)
        self.assertNotIn("referer", keys)
        self.assertFalse(any(k.startswith("sec-fetch-") for k in keys))
        self.assertEqual(out["Content-Type"], "application/json")
        self.assertEqual(out["Authorization"], "Bearer x")

    def test_local_paths(self):
        self.assertTrue(is_local_path("/"))
        self.assertTrue(is_local_path("/app.css"))
        self.assertTrue(is_local_path("/_audit/calls"))
        self.assertFalse(is_local_path("/v1/models"))
        self.assertFalse(is_local_path("/health"))
        self.assertFalse(is_local_path("/v1/chat/completions"))


if __name__ == "__main__":
    unittest.main()
