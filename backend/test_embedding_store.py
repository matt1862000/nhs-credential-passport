"""Tests for persisted semantic embedding storage."""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from backend import db


class EmbeddingStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self._db_path = Path(self._tmpdir.name) / "test.db"
        self._patch = patch.object(db, "DB_PATH", self._db_path)
        self._patch.start()
        db.init_db()

    def tearDown(self) -> None:
        self._patch.stop()
        self._tmpdir.cleanup()

    def test_pack_unpack_roundtrip(self) -> None:
        vec = [0.1, -0.2, 0.3, 1.0]
        packed = db._pack_embedding(vec)
        restored = db._unpack_embedding(packed)
        self.assertEqual(len(restored), len(vec))
        for a, b in zip(restored, vec):
            self.assertAlmostEqual(a, b, places=5)

    def test_topic_embedding_put_get(self) -> None:
        model = "models/gemini-embedding-001"
        th = "abc123"
        vec = [0.5] * 768
        db.embedding_store_put("topic", th, "Fire Safety", model, vec)
        loaded = db.embedding_store_get("topic", th, model)
        self.assertIsNotNone(loaded)
        assert loaded is not None
        self.assertEqual(len(loaded), 768)
        self.assertAlmostEqual(loaded[0], 0.5)

    def test_credential_embedding_put_get(self) -> None:
        model = "models/gemini-embedding-001"
        th = "def456"
        vec = [0.25, 0.75]
        db.embedding_store_put("credential", th, "IPC Level 1", model, vec)
        loaded = db.embedding_store_get("credential", th, model)
        self.assertEqual(loaded, vec)

    def test_missing_returns_none(self) -> None:
        self.assertIsNone(
            db.embedding_store_get("topic", "missing", "models/gemini-embedding-001")
        )


if __name__ == "__main__":
    unittest.main()
