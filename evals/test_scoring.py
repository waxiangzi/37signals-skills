"""评分逻辑与用例集自检（不调用模型）。守卫要双向验：每条断言都配负控。"""
import json
import re
import shutil
import tempfile
import unittest
from pathlib import Path

import run

CASES = json.loads(run.CASES.read_text())
KNOWN = run.known_skills()
META = run.skill_meta()
CASE_MAP = {c["id"]: c for c in CASES}


def stream(*events):
    return [json.dumps(e) for e in events]


def assistant(*blocks):
    return {"type": "assistant", "message": {"content": list(blocks)}}


def skill_call(name):
    return {"type": "tool_use", "name": "Skill", "input": {"skill": name}}


def text(t):
    return {"type": "text", "text": t}


class CaseFileTest(unittest.TestCase):
    def test_scan_set_not_empty(self):
        # 扫描集为空会让下面所有断言静默变绿
        self.assertGreaterEqual(len(KNOWN), 10)
        self.assertEqual(len(META), len(KNOWN))

    def test_ids_unique(self):
        ids = [c["id"] for c in CASES]
        self.assertEqual(len(ids), len(set(ids)))

    def test_expect_any_names_exist(self):
        for c in CASES:
            for name in c.get("expect_any", []):
                self.assertIn(name, KNOWN, f"{c['id']}: 未知技能 {name}")

    def test_every_case_is_positive_or_negative(self):
        for c in CASES:
            self.assertTrue(bool(c.get("expect_any")) ^ (c.get("forbid") == "ALL"), c["id"])

    def test_regexes_compile_and_checks_nonempty(self):
        for c in CASES:
            self.assertTrue(c["checks"], c["id"])
            for chk in c["checks"]:
                self.assertTrue(chk["any"], f"{c['id']}/{chk['name']}")
                for p in chk["any"] + chk.get("avoid", []):
                    re.compile(p)

    def test_has_both_positive_and_negative_cases(self):
        self.assertTrue(any(c.get("forbid") for c in CASES))
        self.assertTrue(any(c.get("expect_any") for c in CASES))

    def test_fixture_exists_and_triggers_paths(self):
        self.assertTrue((run.FIXTURE / "app/helpers/posts_helper.rb").exists())
        self.assertTrue((run.FIXTURE / "Gemfile").exists())


class SkillMetaTest(unittest.TestCase):
    def test_negative_control_human_only(self):
        self.assertIs(META["dhh"], False)
        self.assertIs(META["rails-jobs"], False)

    def test_positive_control_auto(self):
        self.assertIs(META["rails-conventions"], True)
        self.assertIs(META["rails-best-practices-core"], True)

    def test_both_buckets_present_in_cases(self):
        buckets = {run.case_bucket(c, META) for c in CASES} - {None}
        self.assertEqual(buckets, {"auto", "human"})


class BucketTest(unittest.TestCase):
    def test_auto_and_human_and_none(self):
        self.assertEqual(run.case_bucket(CASE_MAP["helper-naming"], META), "auto")
        self.assertEqual(run.case_bucket(CASE_MAP["jobs-idempotent"], META), "human")
        self.assertIsNone(run.case_bucket(CASE_MAP["neg-python-gil"], META))


class RunFailedTest(unittest.TestCase):
    def test_no_result_event_is_failure(self):
        self.assertTrue(run.run_failed({"ended": None, "answer": "半截回答"}))

    def test_empty_answer_is_failure(self):
        self.assertTrue(run.run_failed({"ended": "success", "answer": "  "}))

    def test_success_with_answer(self):
        self.assertFalse(run.run_failed({"ended": "success", "answer": "答案"}))

    def test_max_turns_with_answer_is_data(self):
        self.assertFalse(run.run_failed({"ended": "error_max_turns", "answer": "答案"}))


class ParseTest(unittest.TestCase):
    def test_skill_call_and_namespacing(self):
        p = run.parse_stream(stream(assistant(skill_call("plugin:rails-jobs"), text("ok"))))
        self.assertEqual(p["fired"], ["rails-jobs"])

    def test_skill_md_read_counts(self):
        read = {"type": "tool_use", "name": "Read", "input": {"file_path": "/x/skills/rails-testing/SKILL.md"}}
        self.assertEqual(run.parse_stream(stream(assistant(read)))["fired"], ["rails-testing"])

    def test_ordinary_read_does_not_count(self):
        read = {"type": "tool_use", "name": "Read", "input": {"file_path": "/x/app/models/post.rb"}}
        self.assertEqual(run.parse_stream(stream(assistant(read)))["fired"], [])

    def test_garbage_lines_ignored(self):
        self.assertEqual(run.parse_stream(["not json", "{bad"])["fired"], [])

    def test_denied_and_ended_recorded(self):
        denied = {"type": "system", "subtype": "permission_denied", "tool_name": "Bash"}
        p = run.parse_stream(stream(denied, {"type": "result", "subtype": "success", "result": "x"}))
        self.assertEqual(p["denied"], ["Bash"])
        self.assertEqual(p["ended"], "success")

    def test_cost_and_result(self):
        p = run.parse_stream(stream({"type": "result", "total_cost_usd": 0.2, "num_turns": 3, "result": "答案"}))
        self.assertEqual((p["cost"], p["turns"], p["answer"].strip()), (0.2, 3, "答案"))


class ArtifactTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="artifact-test-"))
        shutil.copytree(run.FIXTURE, self.dir, dirs_exist_ok=True)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_new_and_modified_collected_untouched_skipped(self):
        (self.dir / "app/javascript/controllers/clipboard_controller.js").write_text("export default class {}")
        (self.dir / "app/models/post.rb").write_text("# modified\n")
        out = run.collect_artifacts(self.dir)
        names = [a.split("\n", 1)[0] for a in out]
        self.assertIn("--- app/javascript/controllers/clipboard_controller.js ---", names)
        self.assertIn("--- app/models/post.rb ---", names)
        self.assertNotIn("--- app/helpers/posts_helper.rb ---", names)

    def test_binary_skipped(self):
        (self.dir / "db/test.sqlite3").write_bytes(b"\x00\x01binary")
        self.assertEqual(run.collect_artifacts(self.dir), [])


class ScoreTest(unittest.TestCase):
    pos = {"id": "t", "prompt": "", "expect_any": ["rails-jobs"],
           "checks": [{"name": "a", "any": ["幂等"]}, {"name": "b", "any": ["notified_at"]}]}
    neg = {"id": "n", "prompt": "", "forbid": "ALL", "checks": [{"name": "a", "any": ["GIL"]}]}

    def parsed(self, fired):
        return {"fired": fired, "answer": "", "cost": 0.0, "turns": 0, "denied": [], "ended": "success"}

    def test_positive_hit(self):
        s = run.score_case(self.pos, "做成幂等，用 notified_at", self.parsed(["rails-jobs"]), KNOWN)
        self.assertTrue(s["trigger"])
        self.assertEqual(s["content"], 1.0)

    def test_positive_miss_trigger(self):
        s = run.score_case(self.pos, "幂等", self.parsed(["rails-testing"]), KNOWN)
        self.assertFalse(s["trigger"])
        self.assertEqual(s["content"], 0.5)

    def test_positive_no_fire(self):
        self.assertFalse(run.score_case(self.pos, "", self.parsed([]), KNOWN)["trigger"])

    def test_negative_clean(self):
        self.assertTrue(run.score_case(self.neg, "GIL 是锁", self.parsed([]), KNOWN)["trigger"])

    def test_negative_false_trigger(self):
        self.assertFalse(run.score_case(self.neg, "GIL", self.parsed(["rails-jobs"]), KNOWN)["trigger"])

    def test_negative_ignores_non_rails_skills(self):
        self.assertTrue(run.score_case(self.neg, "GIL", self.parsed(["find-skills"]), KNOWN)["trigger"])

    def test_regex_case_insensitive(self):
        case = {"id": "x", "prompt": "", "expect_any": ["rails-jobs"], "checks": [{"name": "a", "any": ["idempot"]}]}
        self.assertEqual(run.score_case(case, "IDEMPOTENT", self.parsed(["rails-jobs"]), KNOWN)["content"], 1.0)

    def test_avoid_pattern_blocks_hit(self):
        case = {"id": "x", "prompt": "", "expect_any": ["rails-jobs"],
                "checks": [{"name": "a", "any": ["scope"], "avoid": ["select"]}]}
        good = run.score_case(case, "用 scope :published", self.parsed(["rails-jobs"]), KNOWN)["content"]
        bad = run.score_case(case, "Post.all.select { }", self.parsed(["rails-jobs"]), KNOWN)["content"]
        self.assertEqual((good, bad), (1.0, 0.0))

    def def_result(self, case_id, arm, trigger, content, cost=0.1):
        return {"case": case_id, "arm": arm, "cost": cost, "bucket": "auto", "truncated": False,
                "score": {"trigger_kind": "positive", "trigger": trigger, "fired": [], "checks": [],
                          "content": content}}

    def test_aggregate_excludes_infra_errors(self):
        good = self.def_result("a", "default", True, 1.0)
        bad = {"case": "b", "arm": "default", "cost": 0.1, "score": None}
        agg = run.aggregate([good, bad])
        self.assertEqual((agg["n"], agg["errors"], agg["trigger_recall"]), (1, 1, 1.0))

    def test_aggregate_trigger_stats_only_from_default_arm(self):
        d = self.def_result("a", "default", True, 1.0)
        n = self.def_result("a", "noskills", False, 0.5)
        agg = run.aggregate([d, n])
        self.assertEqual(agg["trigger_recall"], 1.0)
        self.assertEqual(agg["content"], 0.75)
        self.assertEqual(agg["composite"], 1.0)

    def test_aggregate_empty(self):
        agg = run.aggregate([])
        self.assertEqual(agg["n"], 0)
        self.assertNotEqual(agg["trigger_recall"], agg["trigger_recall"])  # nan，不是静默的 0


if __name__ == "__main__":
    unittest.main()
