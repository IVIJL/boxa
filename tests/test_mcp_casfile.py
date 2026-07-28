"""ADR 0022: the shared compare-and-swap write primitive."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from mcp import casfile  # noqa: E402


class CasFileTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "file.json")

    def _write(self, data: bytes, path: str | None = None):
        with open(path or self.path, "wb") as fh:
            fh.write(data)

    def _read(self, path: str | None = None) -> bytes:
        with open(path or self.path, "rb") as fh:
            return fh.read()

    def test_swap_writes_when_the_preimage_still_holds(self):
        self._write(b'{"a":1}\n')

        casfile.swap(self.path, b'{"a":1}\n', '{"a":2}\n')

        self.assertEqual(self._read(), b'{"a":2}\n')

    def test_swap_refuses_a_stale_preimage_and_writes_nothing(self):
        self._write(b'{"foreign":true}\n')

        with self.assertRaises(casfile.ConcurrentModification) as caught:
            casfile.swap(self.path, b'{"a":1}\n', '{"a":2}\n')

        self.assertEqual(caught.exception.path, self.path)
        self.assertEqual(self._read(), b'{"foreign":true}\n')

    def test_swap_refuses_when_the_file_must_not_exist_but_does(self):
        self._write(b"appeared\n")

        with self.assertRaises(casfile.ConcurrentModification):
            casfile.swap(self.path, None, "rendered\n")

        self.assertEqual(self._read(), b"appeared\n")

    def test_remove_refuses_a_stale_preimage(self):
        self._write(b"foreign\n")

        with self.assertRaises(casfile.ConcurrentModification):
            casfile.remove(self.path, b"planned\n")

        self.assertTrue(os.path.exists(self.path))

    def test_rollback_restores_boxa_own_write(self):
        self._write(b"before\n")

        with casfile.transaction() as txn:
            casfile.swap(self.path, b"before\n", "after\n")
            errors, concurrent = txn.rollback()

        self.assertEqual((errors, concurrent), ([], []))
        self.assertEqual(self._read(), b"before\n")

    def test_rollback_never_clobbers_a_write_made_after_boxas_own(self):
        self._write(b"before\n")

        with casfile.transaction() as txn:
            casfile.swap(self.path, b"before\n", "after\n")
            self._write(b"foreign\n")
            errors, concurrent = txn.rollback()

        self.assertEqual(errors, [])
        self.assertEqual(concurrent, [self.path])
        self.assertEqual(self._read(), b"foreign\n")

    def test_rollback_removes_a_created_file(self):
        with casfile.transaction() as txn:
            casfile.swap(self.path, None, "rendered\n")
            txn.rollback()

        self.assertFalse(os.path.exists(self.path))

    def test_nested_transaction_hands_its_records_to_the_outer_batch(self):
        self._write(b"before\n")

        with casfile.transaction() as outer:
            with casfile.transaction():
                casfile.swap(self.path, b"before\n", "after\n")
            self.assertEqual(self._read(), b"after\n")
            outer.rollback()

        self.assertEqual(self._read(), b"before\n")

    def test_append_rule_is_written_once(self):
        self._write(b"build/\n")

        first = casfile.append_rule(self.path, "/.mcp.json")
        second = casfile.append_rule(self.path, "/.mcp.json")

        self.assertIsNotNone(first)
        self.assertIsNone(second)
        self.assertEqual(self._read(), b"build/\n/.mcp.json\n")

    def test_append_rollback_removes_only_boxas_line(self):
        self._write(b"build/\n")

        with casfile.transaction() as txn:
            casfile.append_rule(self.path, "/.mcp.json")
            # Git or the user appends its own rule after Boxa's.
            with open(self.path, "ab") as fh:
                fh.write(b"secrets.env\n")
            errors, concurrent = txn.rollback()

        self.assertEqual((errors, concurrent), ([], []))
        self.assertEqual(self._read(), b"build/\nsecrets.env\n")

    def test_append_rollback_removes_a_file_it_created(self):
        with casfile.transaction() as txn:
            casfile.append_rule(self.path, "/.mcp.json")
            txn.rollback()

        self.assertFalse(os.path.exists(self.path))

    def test_record_journals_a_bespoke_write(self):
        self._write(b"before\n")

        with casfile.transaction() as txn:
            with casfile.record(self.path):
                self._write(b"bespoke\n")
            txn.rollback()

        self.assertEqual(self._read(), b"before\n")


if __name__ == "__main__":
    unittest.main()
