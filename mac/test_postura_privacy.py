import tempfile
import unittest

from postura_privacy import Privacy


def face(scale, facing=0, x=0.5):
    return {"face": scale, "facing": facing, "x": x, "y": 0.5}


class VisibilityTests(unittest.TestCase):
    def setUp(self):
        home = tempfile.TemporaryDirectory()
        self.addCleanup(home.cleanup)
        self.model = Privacy(home.name)

    def frame(self, people, now):
        self.model.reload()
        return self.model.update(people, now)

    def test_empty_frame_immediately_reveals_after_close_person(self):
        self.assertTrue(self.frame([face(0.25)], 0)["hide"])
        self.assertEqual(self.frame([], 0.2)["reason"], "empty")
        self.assertFalse(self.frame([], 0.4)["hide"])
        self.assertEqual(self.model.teach("hide"), 0)

    def test_staring_background_person_cannot_hide(self):
        for i in range(20):
            self.assertFalse(self.frame([face(0.05, facing=1)], i * 0.2)["hide"])

    def test_borderline_nearby_frame_is_held_but_background_clears(self):
        self.assertTrue(self.frame([face(0.18)], 0)["hide"])
        self.assertTrue(self.frame([face(0.105)], 0.2)["hide"])
        self.assertFalse(self.frame([face(0.05)], 0.3)["hide"])
        self.assertFalse(self.frame([face(0.105)], 0.4)["hide"])

    def test_nearby_person_hides_after_sustained_attention(self):
        self.assertFalse(self.frame([face(0.105, facing=1)], 0)["hide"])
        for i in range(1, 4):
            self.frame([face(0.105, facing=1)], i * 0.2)
        self.assertEqual(self.frame([face(0.105, facing=1)], 0.8)["reason"], "gaze")

    def test_nearby_person_hides_after_remaining_stationary(self):
        self.assertFalse(self.frame([face(0.105)], 0)["hide"])
        for i in range(1, 6):
            self.frame([face(0.105)], i * 0.2)
        self.assertEqual(self.frame([face(0.105)], 1.2)["reason"], "still")

    def test_feedback_persists_and_newest_correction_wins(self):
        nearby = [face(0.105), face(0.045, x=0.1)]
        self.assertFalse(self.frame(nearby, 0)["hide"])
        self.assertEqual(self.model.teach("hide"), 1)
        self.assertTrue(self.frame(nearby, 0.2)["hide"])
        self.assertEqual(self.model.teach("reveal"), 2)
        self.assertFalse(self.frame(nearby, 0.4)["hide"])
        again = Privacy(self.model.path.rsplit("/", 1)[0])
        self.assertFalse(again.update(nearby, 0)["hide"])

    def test_second_nearby_person_keeps_cover_active(self):
        self.frame([face(0.16)], 0)
        self.model.teach("reveal")
        self.assertFalse(self.frame([face(0.16)], 0.2)["hide"])
        self.assertTrue(self.frame([face(0.16), face(0.30, x=0.1)], 0.4)["hide"])
        self.assertEqual(self.model.teach("reveal"), 0)


if __name__ == "__main__":
    unittest.main()
