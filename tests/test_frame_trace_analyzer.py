import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "analyze-frame-trace.py"
SPEC = importlib.util.spec_from_file_location("frame_trace_analyzer", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class FrameTraceAnalyzerTest(unittest.TestCase):
    def test_percentile_and_empty_summary_edges(self):
        self.assertIsNone(MODULE.percentile([], 0.5))
        self.assertEqual(MODULE.percentile([4.0, 1.0, 3.0, 2.0], 0.5), 2.0)
        self.assertEqual(MODULE.percentile([4.0, 1.0, 3.0, 2.0], 0.95), 4.0)
        self.assertEqual(MODULE.summary([])["count"], 0)
        self.assertIsNone(MODULE.summary([])["p99_ms"])

    def test_analyze_tracks_cadence_freshness_and_frame_id_faults(self):
        rows = [
            {
                "frame_id": 10,
                "capture_ns": 1_000_000_000,
                "input_queued_ns": 1_004_000_000,
                "output_release_requested_ns": 1_010_000_000,
                "surface_rendered_ns": 1_020_000_000,
            },
            {
                "frame_id": 10,
                "capture_ns": 1_016_000_000,
                "input_queued_ns": 1_020_000_000,
                "output_release_requested_ns": 1_027_000_000,
                "surface_rendered_ns": 1_036_000_000,
            },
            {
                "frame_id": 13,
                "capture_ns": 1_032_000_000,
                "input_queued_ns": 1_036_000_000,
                "output_release_requested_ns": 1_044_000_000,
                "surface_rendered_ns": 1_052_000_000,
            },
            {
                "frame_id": 12,
                "capture_ns": 1_048_000_000,
                "input_queued_ns": 1_052_000_000,
                "output_release_requested_ns": 1_061_000_000,
                "surface_rendered_ns": 1_068_000_000,
            },
        ]

        report = MODULE.analyze(rows, 60.0)

        self.assertEqual(report["rows"], 4)
        self.assertEqual(report["rendered_rows"], 4)
        self.assertEqual(report["duplicates"], 1)
        self.assertEqual(report["skipped"], 2)
        self.assertEqual(report["reordered"], 1)
        self.assertEqual(report["first_frame_id"], 10)
        self.assertEqual(report["last_frame_id"], 13)
        self.assertEqual(report["inter_frame_outside_expected_band"], 0)
        self.assertAlmostEqual(report["freshness_capture_to_surface"]["p50_ms"], 20.0)
        self.assertAlmostEqual(report["decoder_queue_input_to_release"]["max_ms"], 9.0)

    def test_load_rows_ignores_comments_and_malformed_rows(self):
        data = """# generated fixture\nframe_id,capture_ns,input_queued_ns,output_release_requested_ns,surface_rendered_ns\n1,10,20,30,40\nbad,row,that,is,ignored\n2,50,60,70,80\n"""
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "trace.csv"
            path.write_text(data)
            rows = MODULE.load_rows(path)

        self.assertEqual([row["frame_id"] for row in rows], [1, 2])

    def test_zero_target_fps_is_safe(self):
        report = MODULE.analyze([], 0.0)
        self.assertEqual(report["expected_interval_ms"], 0.0)
        self.assertEqual(report["cadence_band_ms"], [0.0, 0.0])
        self.assertIsNone(report["inter_frame"]["rendered_fps"])


if __name__ == "__main__":
    unittest.main()
