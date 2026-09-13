"""Regression tests for bin/_mwlib.py's safe_summary().

safe_summary() is the single choke point every CLI tool's error output goes
through for an authentication-response body (bin/makerworld-login's TFA/code/
unexpected-response paths, bin/makerworld-refresh, bin/makerworld-token
--check). Every one of those call sites is just
`print(<fixed local string> + mw.safe_summary(response))`, so proving a
canary can never appear in safe_summary()'s return value is equivalent to
proving it can never reach stdout/stderr through any of them.
"""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin"))
import _mwlib as mw  # noqa: E402

CANARY = "CANARY-SECRET-3f9a7c2e8b41"


class SafeSummaryCanaryTests(unittest.TestCase):
    def test_canary_as_string_in_every_allowlisted_field_is_withheld(self):
        for key in mw.SAFE_RESPONSE_KEYS:
            with self.subTest(key=key):
                out = mw.safe_summary({key: CANARY})
                self.assertNotIn(CANARY, out)

    def test_canary_in_every_allowlisted_field_at_once(self):
        obj = {key: CANARY for key in mw.SAFE_RESPONSE_KEYS}
        out = mw.safe_summary(obj)
        self.assertNotIn(CANARY, out)

    def test_canary_in_non_allowlisted_and_nested_fields_is_withheld(self):
        obj = {
            "accessToken": CANARY,
            "refreshToken": CANARY,
            "tfaKey": CANARY,
            "Set-Cookie": CANARY,
            "nested": {"accessToken": CANARY},
        }
        out = mw.safe_summary(obj)
        self.assertNotIn(CANARY, out)

    def test_canary_as_a_list_or_dict_value_in_an_allowlisted_field(self):
        # A server could put a secret in a nested shape under an allowlisted
        # key too, not just a bare string.
        for shape in (CANARY, [CANARY], {"inner": CANARY}, {"code": CANARY}):
            with self.subTest(shape=shape):
                out = mw.safe_summary({"code": shape, "status": shape, "success": shape})
                self.assertNotIn(CANARY, out)

    def test_non_string_scalars_in_allowlisted_fields_are_kept(self):
        out = mw.safe_summary({"code": 400, "status": 1, "success": False})
        self.assertIn("code=400", out)
        self.assertIn("status=1", out)
        self.assertIn("success=False", out)

    def test_non_dict_input_never_raises_and_withholds_everything(self):
        for bad in (None, [], [CANARY], "a string", 42, True):
            with self.subTest(bad=bad):
                out = mw.safe_summary(bad)
                self.assertNotIn(CANARY, out)


if __name__ == "__main__":
    unittest.main()
