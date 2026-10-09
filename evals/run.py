#!/usr/bin/env python3
"""技能评估运行器：在合成 Rails 夹具里无头运行 claude -p，按触发 + 内容两轴打分。

用法:
  python3 evals/run.py --model cc/deepseek-flash          # 默认臂
  python3 evals/run.py --arms default,noskills --jobs 3   # 加无技能基线，算技能增益
  python3 evals/run.py --only helper-naming --runs 3
断言自检（在 evals/ 目录）: python3 -m unittest test_scoring
"""
import argparse
import gzip
import json
import re
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
FIXTURE = HERE / "fixture"
CASES = HERE / "cases.json"
RESULTS = HERE / "results"
TOOLS = "Read,Grep,Glob,Skill,Bash,Write,Edit"
# 技能正文要求先跑探针；工作目录是一次性夹具副本，Bash 只放行只读与一次性求值的命令
_READONLY = ["ruby -e:*", "python3 -c:*", "node -e:*", "grep:*", "ls:*", "find:*",
             "cat:*", "head:*", "tail:*", "wc:*", "git status:*", "git diff:*", "git log:*"]
# 用户级 hook 会把命令改写成 `rtk <子命令>`（cat/head -> rtk read、ls -> rtk ls ...），
# 改写后原命令的白名单就失配，只能整体放行 rtk；夹具是一次性 /tmp 副本，风险可接受。
BASH_ALLOW = [f"Bash({p})" for p in _READONLY] + ["Bash(rtk:*)", "Bash(echo:*)", "Skill"]
# 本机 claude 会因未知 frontmatter 键整个丢弃技能（`paths` 即是）；注入副本时剥掉
SKILL_FM_DROP = ("paths",)
RETRIES = 2
ARTIFACT_CAP = 20_000
ANSWER_CAP = 60_000


def known_skills():
    return sorted(p.parent.name for p in (REPO / "skills").glob("*/SKILL.md"))


def skill_meta():
    """name -> 是否可被模型自动调用（frontmatter 里的 disable-model-invocation）。"""
    meta = {}
    for p in (REPO / "skills").glob("*/SKILL.md"):
        text = p.read_text(encoding="utf-8", errors="replace")
        m = re.match(r"^---\s*\n(.*?)\n---", text, re.S)
        fm = m.group(1) if m else ""
        meta[p.parent.name] = not re.search(
            r"^disable-model-invocation:\s*(true|yes|1|on)\s*$", fm, re.M | re.IGNORECASE)
    return meta


def normalize_skill(name):
    return name.split(":")[-1]


def case_bucket(case, meta):
    """用例期望的技能里有没有可自动调用的；没有 = 只能靠路由/人工发现。"""
    names = case.get("expect_any") or []
    if not names:
        return None
    return "auto" if any(meta.get(n, False) for n in names) else "human"


def run_failed(parsed):
    """没有 result 事件（超时/崩溃）或没有回答 = 基础设施失败，不是数据。"""
    return parsed["ended"] is None or not parsed["answer"].strip()


def parse_stream(lines):
    """从 stream-json 事件里提取：触发的技能、回答文本、成本、轮数、被拒的工具。"""
    fired, texts, denied, cost, turns, result_text, ended = [], [], [], 0.0, 0, None, None
    for line in lines:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = ev.get("type")
        if kind == "assistant":
            for block in ev.get("message", {}).get("content", []):
                if block.get("type") == "text":
                    texts.append(block["text"])
                elif block.get("type") == "tool_use":
                    inp = block.get("input", {})
                    if block.get("name") == "Skill" and inp.get("skill"):
                        fired.append(normalize_skill(inp["skill"]))
                    elif block.get("name") == "Read":
                        m = re.search(r"/([^/]+)/SKILL\.md$", inp.get("file_path", ""))
                        if m:
                            fired.append(m.group(1))
        elif kind == "system" and ev.get("subtype") == "permission_denied":
            tool = ev.get("tool_name") or (ev.get("tool") or {}).get("name") or "?"
            denied.append(tool)
        elif kind == "result":
            cost = ev.get("total_cost_usd", 0.0) or 0.0
            turns = ev.get("num_turns", 0) or 0
            result_text = ev.get("result")
            ended = ev.get("subtype")
    answer = "\n".join(texts)
    if result_text and result_text not in answer:
        answer += "\n" + result_text
    return {"fired": sorted(set(fired)), "answer": answer, "cost": cost, "turns": turns,
            "denied": denied, "ended": ended}


def collect_artifacts(workdir):
    """模型在夹具副本里新增/修改的文本文件，并入内容评分（写了文件但没贴代码时兜底）。"""
    out = []
    for p in sorted(workdir.rglob("*")):
        if not p.is_file():
            continue
        rel = p.relative_to(workdir)
        if rel.parts[0] in (".git", ".claude", "node_modules", "tmp", "log"):
            continue
        try:
            cur = p.read_bytes()
            orig = FIXTURE / rel
            if orig.exists() and orig.read_bytes() == cur:
                continue
            if b"\x00" in cur[:1024]:
                continue
            out.append(f"--- {rel} ---\n" + cur[:ARTIFACT_CAP].decode("utf-8", errors="replace"))
        except OSError:
            continue
    return out


def score_case(case, answer, parsed, known):
    """触发轴 0~1 + 内容轴 0~1；noskills 臂没有触发轴。"""
    fired = set(parsed["fired"]) & set(known)
    if case.get("forbid") == "ALL":
        trigger = not fired
        trigger_kind = "negative"
    else:
        trigger = bool(fired & set(case["expect_any"]))
        trigger_kind = "positive"
    check_results = []
    for check in case["checks"]:
        found = lambda pats: any(re.search(p, answer, re.IGNORECASE) for p in pats)
        hit = found(check["any"]) and not found(check.get("avoid", []))
        check_results.append({"name": check["name"], "pass": hit})
    passed = sum(c["pass"] for c in check_results)
    return {
        "trigger_kind": trigger_kind,
        "trigger": trigger,
        "fired": sorted(fired),
        "checks": check_results,
        "content": passed / len(check_results) if check_results else 1.0,
    }


def stage_skills(workdir):
    """把仓库技能作为项目技能注进夹具副本的 .claude/skills/。

    裸技能目录（`--add-dir REPO/skills`）在当前 claude 版本不会注册技能，只有
    `<cwd>/.claude/skills/<name>/SKILL.md` 才会进 init 的技能清单；frontmatter 里
    本机不认的键会连技能一起丢掉，所以要就地重写 SKILL.md。
    """
    dest = workdir / ".claude" / "skills"
    staged = []
    for skill in sorted((REPO / "skills").glob("*/SKILL.md")):
        out = dest / skill.parent.name
        shutil.copytree(skill.parent, out, dirs_exist_ok=True)
        text = (out / "SKILL.md").read_text(encoding="utf-8")
        m = re.match(r"^---\s*\n(.*?)\n---\s*\n", text, re.S)
        if not m:
            staged.append(skill.parent.name)
            continue
        drop = re.compile(r"^(%s):" % "|".join(SKILL_FM_DROP))
        keep, skipping = [], False
        for line in m.group(1).splitlines():
            if re.match(r"^\S", line):
                skipping = bool(drop.match(line))
            if not skipping:
                keep.append(line)
        (out / "SKILL.md").write_text("---\n" + "\n".join(keep) + "\n---\n" + text[m.end():],
                                      encoding="utf-8")
        staged.append(skill.parent.name)
    return staged


def run_one(case, arm, args, known, meta):
    workdir = Path(tempfile.mkdtemp(prefix=f"skilleval-{case['id']}-"))
    try:
        shutil.copytree(FIXTURE, workdir, dirs_exist_ok=True)
        if arm != "noskills":
            stage_skills(workdir)
        cmd = [
            "claude", "-p", case["prompt"],
            "--output-format", "stream-json", "--verbose",
            "--max-turns", str(args.max_turns),
            "--max-budget-usd", str(args.budget),
            "--tools", TOOLS,
            "--allowedTools", *BASH_ALLOW,
            "--permission-mode", "acceptEdits",
            "--strict-mcp-config",
            "--no-session-persistence",
        ]
        if arm == "noskills":
            cmd.append("--disable-slash-commands")
        else:
            for d in (REPO / "skills", Path.home() / ".claude/skills", Path.home() / ".agents/skills"):
                cmd += ["--add-dir", str(d)]
        if args.model:
            cmd += ["--model", args.model]
        started = time.time()
        out, err, parsed, attempt = "", "", None, 0
        for attempt in range(RETRIES + 1):
            try:
                proc = subprocess.run(cmd, cwd=workdir, capture_output=True, text=True, timeout=args.timeout)
                out, err = proc.stdout, proc.stderr
            except subprocess.TimeoutExpired as e:
                out, err = (e.stdout or ""), f"timeout>{args.timeout}s"
                if isinstance(out, bytes):
                    out = out.decode(errors="replace")
            parsed = parse_stream(out.splitlines())
            # 半截回答不是数据：必须见到 result 事件才算跑完
            if not run_failed(parsed):
                break
        (RESULTS / "raw" / args.stamp).mkdir(parents=True, exist_ok=True)
        (RESULTS / "raw" / args.stamp / f"{arm}--{case['id']}.jsonl.gz").write_bytes(gzip.compress(out.encode()))

        errored = run_failed(parsed)
        artifacts = collect_artifacts(workdir)
        answer = (parsed["answer"] + "\n" + "\n".join(artifacts))[:ANSWER_CAP]
        return {
            "case": case["id"], "arm": arm, "bucket": case_bucket(case, meta),
            "seconds": round(time.time() - started, 1),
            "cost": parsed["cost"], "turns": parsed["turns"],
            "denied": parsed["denied"], "attempts": attempt + 1, "ended": parsed["ended"],
            "truncated": parsed["ended"] not in (None, "success"),
            "artifacts": [a.split("\n", 1)[0].strip("- ") for a in artifacts],
            "error": (err.strip()[-200:] or "无 result 事件") if errored else None,
            "score": None if errored else score_case(case, answer, parsed, known),
            "answer_head": parsed["answer"][:300],
        }
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def aggregate(results):
    ok = [r for r in results if r["score"]]
    default = [r for r in ok if r["arm"] == "default"]
    pos = [r for r in default if r["score"]["trigger_kind"] == "positive"]
    neg = [r for r in default if r["score"]["trigger_kind"] == "negative"]
    mean = lambda xs: sum(xs) / len(xs) if xs else float("nan")
    fired_count = {}
    for r in ok:
        for s in r["score"]["fired"]:
            fired_count[s] = fired_count.get(s, 0) + 1
    return {
        "n": len(ok), "errors": len(results) - len(ok),
        "trigger_recall": mean([r["score"]["trigger"] for r in pos]),
        "false_trigger_rate": mean([not r["score"]["trigger"] for r in neg]),
        "content": mean([r["score"]["content"] for r in ok]),
        "composite": mean([0.5 * r["score"]["trigger"] + 0.5 * r["score"]["content"] for r in default]),
        "cost": sum(r["cost"] for r in results), "fired_count": fired_count,
    }


def report(results, arms):
    lines = []
    mean = lambda xs: f"{sum(xs) / len(xs):.0%}" if xs else "-"
    for arm in arms:
        rs = [r for r in results if r["arm"] == arm]
        agg = aggregate(rs)
        lines.append(f"\n## 臂：{arm}（{agg['n']} 个有效，{agg['errors']} 个基础设施失败，${agg['cost']:.2f}）")
        if arm == "default":
            recall = lambda bucket: [r["score"]["trigger"] for r in rs if r["score"]
                                     and r["score"]["trigger_kind"] == "positive" and r["bucket"] == bucket]
            auto, human = recall("auto"), recall("human")
            lines.append(f"- 触发召回（正例）：{agg['trigger_recall']:.0%}"
                         f"（可自动调用 {len(auto)} 例 {mean(auto)}；仅人工调用 {len(human)} 例 {mean(human)}）")
            lines.append(f"- 误触发率（反例，越低越好）：{agg['false_trigger_rate']:.0%}")
            lines.append(f"- 各技能被触发次数：{agg['fired_count']}")
        lines.append(f"- 内容通过率：{agg['content']:.0%}")
        if arm == "default":
            lines.append(f"- 综合分（触发 50% + 内容 50%）：{agg['composite']:.0%}")
        trunc = [r["case"] for r in rs if r.get("truncated")]
        if trunc:
            lines.append(f"- ⚠ 被 max-turns/预算截断（内容分不可信）：{trunc}")
        lines.append("\n| 用例 | 触发 | 内容 | 触发了 | 秒 | $ |\n|---|---|---|---|---|---|")
        for r in rs:
            if not r["score"]:
                lines.append(f"| {r['case']} | 失败 | - | {r['error']} | {r['seconds']} | {r['cost']:.2f} |")
                continue
            s = r["score"]
            ok_checks = sum(c["pass"] for c in s["checks"])
            trig = "-" if arm == "noskills" else ("✓" if s["trigger"] else "✗")
            denied = f" /{len(r['denied'])}拒" if r["denied"] else ""
            lines.append(f"| {r['case']} | {trig} | {ok_checks}/{len(s['checks'])} | {','.join(s['fired']) or '-'} | {r['seconds']}{denied} | {r['cost']:.2f} |")
    if "default" in arms and "noskills" in arms:
        d = aggregate([r for r in results if r["arm"] == "default"])["content"]
        b = aggregate([r for r in results if r["arm"] == "noskills"])["content"]
        lines.append(f"\n## 技能增益\n内容通过率 default {d:.0%} − noskills {b:.0%} = {d - b:+.0%}")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arms", default="default")
    ap.add_argument("--only", default="")
    ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--jobs", type=int, default=3)
    ap.add_argument("--max-turns", type=int, default=30)
    ap.add_argument("--budget", type=float, default=1.5)
    ap.add_argument("--timeout", type=int, default=420)
    ap.add_argument("--model", default="")
    args = ap.parse_args()

    cases = json.loads(CASES.read_text())
    if args.only:
        wanted = set(args.only.split(","))
        cases = [c for c in cases if c["id"] in wanted]
    arms = args.arms.split(",")
    known, meta = known_skills(), skill_meta()
    model = args.model or "env-default"
    args.stamp = datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + re.sub(r"[^A-Za-z0-9.]+", "-", model)
    jobs = [(c, a) for a in arms for c in cases for _ in range(args.runs)]
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(lambda j: run_one(j[0], j[1], args, known, meta), jobs))

    head = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=REPO, capture_output=True, text=True).stdout.strip()
    text = (f"# 技能评估 {datetime.now():%Y-%m-%d %H:%M}（模型 {model}，fork HEAD {head}，"
            f"runs={args.runs}，技能以 .claude/skills 注入夹具、剥掉 {','.join(SKILL_FM_DROP)}）"
            + report(results, arms))
    RESULTS.mkdir(exist_ok=True)
    (RESULTS / f"{args.stamp}.json").write_text(json.dumps({"head": head, "model": model, "results": results}, ensure_ascii=False, indent=2))
    (RESULTS / f"{args.stamp}.md").write_text(text)
    print(text)
    sys.exit(1 if any(r["score"] is None for r in results) else 0)


if __name__ == "__main__":
    main()
