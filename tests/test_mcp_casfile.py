"""ADR 0022: the shared compare-and-swap write primitive."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from unittest import mock

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






    def test_swap_does_not_recreate_a_file_deleted_concurrently(self):
        """An empty pre-image is an EMPTY FILE, never a missing one."""
        self._write(b"")
        os.unlink(self.path)

        with self.assertRaises(casfile.ConcurrentModification):
            casfile.swap(self.path, b"", "rendered\n")

        self.assertFalse(os.path.exists(self.path))

    def test_swap_writes_against_a_genuinely_empty_file(self):
        self._write(b"")

        casfile.swap(self.path, b"", "rendered\n")

        self.assertEqual(self._read(), b"rendered\n")

    def test_swap_does_not_overwrite_an_empty_file_created_concurrently(self):
        """A missing pre-image is ``None``; an empty file is a foreign create."""
        self._write(b"")

        with self.assertRaises(casfile.ConcurrentModification):
            casfile.swap(self.path, None, "rendered\n")

        self.assertEqual(self._read(), b"")

    def test_remove_refuses_a_file_deleted_concurrently(self):
        self._write(b"")
        os.unlink(self.path)

        with self.assertRaises(casfile.ConcurrentModification):
            casfile.remove(self.path, b"")

    def test_preimage_keeps_absence_distinct_from_empty_text(self):
        self.assertIsNone(casfile.preimage(None))
        self.assertEqual(casfile.preimage(""), b"")

    def _edit_while_the_temp_file_is_written(self, data: bytes):
        """Land a foreign edit inside the writer's own write window.

        The writer has already created and fsynced its temporary file; the edit
        arrives in the instant before ``os.replace``. A call-site-only check
        cannot see it, which is exactly the window under test.
        """
        real_fsync = os.fsync
        landed: list[bool] = []

        def fsync(fd):
            result = real_fsync(fd)
            if not landed:
                landed.append(True)
                self._write(data)
            return result

        return mock.patch.object(casfile.os, "fsync", fsync)

    def test_swap_refuses_an_edit_landing_while_the_temp_file_is_written(self):
        self._write(b"before\n")

        with self._edit_while_the_temp_file_is_written(b"foreign\n"):
            with self.assertRaises(casfile.ConcurrentModification) as caught:
                casfile.swap(self.path, b"before\n", "after\n")

        self.assertEqual(caught.exception.path, self.path)
        self.assertEqual(self._read(), b"foreign\n")
        # Nothing written and no temp residue left behind.
        self.assertEqual(os.listdir(self.tmp.name), ["file.json"])

    def test_swap_refuses_a_delete_landing_while_the_temp_file_is_written(self):
        self._write(b"before\n")
        real_fsync = os.fsync
        landed: list[bool] = []

        def fsync(fd):
            result = real_fsync(fd)
            if not landed:
                landed.append(True)
                os.unlink(self.path)
            return result

        with mock.patch.object(casfile.os, "fsync", fsync):
            with self.assertRaises(casfile.ConcurrentModification):
                casfile.swap(self.path, b"before\n", "after\n")

        self.assertFalse(os.path.exists(self.path))

    def test_swap_json_refuses_an_edit_landing_in_the_same_window(self):
        self._write(b'{"a":1}\n')

        with self._edit_while_the_temp_file_is_written(b'{"foreign":true}\n'):
            with self.assertRaises(casfile.ConcurrentModification):
                casfile.swap_json(self.path, b'{"a":1}\n', {"a": 2}, 0o600)

        self.assertEqual(self._read(), b'{"foreign":true}\n')

    def test_swap_still_writes_when_nothing_lands_in_the_window(self):
        self._write(b"before\n")

        with self._edit_while_the_temp_file_is_written(b"before\n"):
            casfile.swap(self.path, b"before\n", "after\n")

        self.assertEqual(self._read(), b"after\n")

    def test_swap_reports_a_writer_that_bypasses_the_conditional_replace(self):
        self._write(b"before\n")

        def rogue(path, text):
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(text)

        with self.assertRaises(casfile.WriteError):
            casfile.swap(self.path, b"before\n", "after\n", writer=rogue)

    def test_concurrent_conflict_follows_a_translated_error(self):
        original = casfile.ConcurrentModification(self.path)
        translated = RuntimeError("refused")
        translated.__cause__ = original

        self.assertIs(casfile.concurrent_conflict(translated), original)
        self.assertIsNone(casfile.concurrent_conflict(RuntimeError("other")))

    def test_rollback_refuses_an_edit_landing_while_it_writes_its_temp_file(self):
        """The compensation compares the post-image right before its replace."""
        self._write(b"before\n")

        with casfile.transaction() as txn:
            casfile.swap(self.path, b"before\n", "after\n")
            with self._edit_while_the_temp_file_is_written(b"foreign\n"):
                errors, concurrent = txn.rollback()

        self.assertEqual(errors, [])
        self.assertEqual(concurrent, [self.path])
        self.assertEqual(self._read(), b"foreign\n")
        # Nothing restored and no rollback temp residue left behind.
        self.assertEqual(os.listdir(self.tmp.name), ["file.json"])



    def test_record_journals_a_bespoke_write(self):
        self._write(b"before\n")

        with casfile.transaction() as txn:
            with casfile.record(self.path):
                self._write(b"bespoke\n")
            txn.rollback()

        self.assertEqual(self._read(), b"before\n")


if __name__ == "__main__":
    unittest.main()
