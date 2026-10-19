#!/usr/bin/env python3
"""Arm and collect persistent Vita3K iOS diagnostics without restarting the app."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

BUNDLE = "dev.vita3k.VeebSE"
ROOT = Path(__file__).resolve().parents[3]
BOUNDS = [1000, 2000, 4000, 8000, 12000, 16667, 20000, 25000, 33334,
          50000, 100000, 250000, 500000, 1000000, None]


def run(args):
    result = subprocess.run(args, text=True, capture_output=True, timeout=60)
    if result.returncode:
        raise RuntimeError(f"{' '.join(map(str, args))}\n{result.stderr or result.stdout}")
    return result.stdout.strip()


class Target:
    def __init__(self, state):
        self.state = state
        self.documents = None
        if state.get("documents"):
            self.documents = Path(state["documents"])
        elif state.get("simulator"):
            self.documents = Path(run(["xcrun", "simctl", "get_app_container",
                                       state["simulator"], state["bundle"], "data"])) / "Documents"

    def transfer(self, direction, source, destination, domain="appDataContainer"):
        args = ["xcrun", "devicectl", "device", "copy", direction, "--device",
                self.state["device"], "--domain-type", domain, "--source", str(source),
                "--destination", str(destination), "--timeout", "45"]
        if domain == "appDataContainer":
            args += ["--domain-identifier", self.state["bundle"]]
        run(args)

    def put(self, source, relative):
        if self.documents:
            destination = self.documents / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        else:
            self.transfer("to", source, "Documents/" + relative)

    def get(self, relative, destination):
        destination = Path(destination)
        destination.parent.mkdir(parents=True, exist_ok=True)
        if self.documents:
            source = self.documents / relative
            if source.is_dir():
                shutil.copytree(source, destination)
            else:
                shutil.copy2(source, destination)
        else:
            self.transfer("from", "Documents/" + relative, destination)

    def read(self, relative):
        with tempfile.TemporaryDirectory(prefix="vita3k-diagnostic-read-") as temporary:
            destination = Path(temporary) / "file.txt"
            self.get(relative, destination)
            return destination.read_text()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def set_mode(target, mode):
    with tempfile.TemporaryDirectory(prefix="vita3k-diagnostic-mode-") as temporary:
        marker = Path(temporary) / "diagnostics-mode.txt"
        marker.write_text(mode + "\n")
        target.put(marker, marker.name)
    if target.read("diagnostics-mode.txt").strip() != mode:
        raise RuntimeError("Marker read-back did not match. Mode is not armed.")


def arm(args):
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    case = (args.case or ROOT / "build" / "diagnostics" / f"{stamp}-{args.mode}").resolve()
    case.mkdir(parents=True, exist_ok=False)
    state = {key: getattr(args, key) for key in ("mode", "device", "simulator", "bundle")}
    state["documents"] = str(args.documents.resolve()) if args.documents else None
    state["requested_unix_us"] = time.time_ns() // 1000
    state["state"] = "preparing"
    target = Target(state)
    try:
        state["previous_mode"] = target.read("diagnostics-mode.txt").strip()
    except (OSError, RuntimeError):
        state["previous_mode"] = None
    try:
        state["previous_active"] = target.read("diagnostics/active.txt")
    except (OSError, RuntimeError):
        state["previous_active"] = None
    write_json(case / "case.json", state)
    set_mode(target, args.mode)
    state["state"] = "armed_waiting_for_app_restart"
    write_json(case / "case.json", state)
    (case / "source-revision.txt").write_text(run(["git", "-C", str(ROOT), "rev-parse", "HEAD"]) + "\n")
    (case / "source-status.txt").write_text(run(["git", "-C", str(ROOT), "status", "--short"]) + "\n")
    print(f"Armed {args.mode}; marker verified. Case: {case}")
    print("Restart Vita3K, then run status --case PATH before reproducing. JIT may need re-enabling.")


def load_case(case):
    state = json.loads((case / "case.json").read_text())
    return state, Target(state)


def parse_values(text):
    return dict(line.split("=", 1) for line in text.splitlines() if "=" in line)


def status(args):
    state, target = load_case(args.case)
    active_text = target.read("diagnostics/active.txt")
    active = parse_values(active_text)
    if active.get("mode") != state["mode"] or active_text == state.get("previous_active"):
        raise RuntimeError("Mode not acknowledged by a fresh app launch. Restart the app with a diagnostic-capable build.")
    capture = active.get("capture", "")
    if not re.fullmatch(r"capture-\d+", capture):
        raise RuntimeError("Invalid or missing capture ID in active.txt")
    manifest = target.read(f"diagnostics/{capture}/manifest.txt")
    metadata = parse_values(manifest)
    if metadata.get("mode") != state["mode"] or metadata.get("schema") != "1":
        raise RuntimeError("Capture manifest does not match the requested mode/schema")
    state["active_capture"] = capture
    state["state"] = "ready_for_reproduction"
    write_json(args.case / "case.json", state)
    (args.case / "acknowledged-manifest.txt").write_text(manifest)
    print(active_text + manifest)


def collect(args):
    state, target = load_case(args.case)
    # Never launch, terminate, reinstall, or clean caches while collecting evidence.
    destination = args.case / ("collection-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ"))
    destination.mkdir(parents=True)
    errors = {}
    # Capture the confirmed scene before potentially slow transfers of old logs.
    if args.screenshot:
        try:
            if state.get("simulator"):
                run(["xcrun", "simctl", "io", state["simulator"], "screenshot", str(destination / "screen.png")])
            elif state.get("device"):
                run(["xcrun", "devicectl", "device", "capture", "screenshot", "--device", state["device"],
                     "--destination", str(destination / "screen.png")])
            else:
                errors["screenshot"] = "A Documents-only target cannot capture its screen."
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            errors["screenshot"] = str(error)
    for relative in ("diagnostics", "config", "logs/vita3k.log", "logs/vita3k.1.log", "logs/vita3k.2.log",
                     "startup-probe.txt", "session-probe-report.txt", "diagnostics-mode.txt"):
        try:
            target.get(relative, destination / relative)
        except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
            errors[relative] = str(error)
    # Only fetch specifically selected OS crash files; don't collect unrelated apps' reports.
    for remote in args.crash_file:
        try:
            if not state.get("device"):
                raise RuntimeError("--crash-file requires a physical device target")
            output = destination / "crashes" / Path(remote).name
            output.parent.mkdir(exist_ok=True)
            target.transfer("from", remote, output, domain="systemCrashLogs")
        except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
            errors[remote] = str(error)
    write_json(destination / "collection-errors.json", errors)
    hashes = {}
    for path in destination.rglob("*"):
        if path.is_file():
            with path.open("rb") as stream:
                digest = hashlib.sha256()
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
                hashes[str(path.relative_to(destination))] = digest.hexdigest()
    write_json(destination / "sha256.json", hashes)
    state["last_collection"] = str(destination)
    state["state"] = "collected"
    write_json(args.case / "case.json", state)
    print(f"Evidence: {destination}")
    print(f"Missing/failed optional files: {len(errors)} (see collection-errors.json)")
    if not list(destination.rglob("manifest.txt")):
        raise RuntimeError("No diagnostic capture was retrieved; fallback logs may still be available.")


def disarm(args):
    state, target = load_case(args.case)
    set_mode(target, "off")
    state["state"] = "disarmed_next_restart"
    write_json(args.case / "case.json", state)
    print("Mode off verified. Takes effect on the next app restart; existing evidence is preserved.")


def analyze(args):
    groups = {}
    malformed = 0
    # Rotation order is irrelevant for aggregates. Group by capture AND game ordinal.
    for path in args.path.rglob("telemetry*.jsonl"):
        for line in path.read_text(errors="replace").splitlines():
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                malformed += 1
                continue
            key = (str(path.parent), row.get("game"), row.get("title_id"))
            group = groups.setdefault(key, {"metrics": {}, "last_health": None, "stages": [], "errors": []})
            kind, detail = row.get("event"), row.get("detail", "")
            if kind == "health":
                if group["last_health"] is None or row["elapsed_us"] > group["last_health"]["elapsed_us"]:
                    group["last_health"] = row
            elif kind == "stage":
                group["stages"].append([row["elapsed_us"], detail])
            elif kind == "error":
                group["errors"].append(detail)
            elif kind == "metric":
                fields = dict(token.split("=", 1) for token in detail.split())
                if not int(fields["count"]):
                    continue
                metric = group["metrics"].setdefault(fields["name"], {"count": 0, "sum_us": 0, "max_us": 0, "histogram": [0] * len(BOUNDS)})
                metric["count"] += int(fields["count"])
                metric["sum_us"] += int(fields["sum_us"])
                metric["max_us"] = max(metric["max_us"], int(fields["max_us"]))
                metric["histogram"] = [a + b for a, b in zip(metric["histogram"], map(int, fields["histogram"].split(",")))]
    output = []
    for (capture, game, title), group in sorted(groups.items()):
        group["stages"].sort()
        for metric in group["metrics"].values():
            metric["mean_ms"] = metric["sum_us"] / metric["count"] / 1000
            for percentile in (50, 95, 99):
                cumulative = 0
                for bound, count in zip(BOUNDS, metric["histogram"]):
                    cumulative += count
                    if cumulative >= metric["count"] * percentile / 100:
                        metric[f"p{percentile}_upper_bound_ms"] = bound / 1000 if bound else ">1000"
                        break
        output.append(dict(capture=capture, game=game, title_id=title, **group))
    print(json.dumps({"malformed_lines": malformed, "games": output,
                      "note": "Percentiles are histogram upper bounds, not exact values. Intervals include pauses/loading; compare matched running windows. CPU wall stages are not GPU execution times. Missing end events do not prove a crash."}, ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("arm")
    command.add_argument("--mode", choices=("compat", "performance", "graphics"), required=True)
    target = command.add_mutually_exclusive_group(required=True)
    target.add_argument("--device")
    target.add_argument("--simulator")
    target.add_argument("--documents", type=Path)
    command.add_argument("--bundle", default=BUNDLE)
    command.add_argument("--case", type=Path)
    command.set_defaults(func=arm)
    for name, function in (("status", status), ("collect", collect), ("disarm", disarm)):
        command = commands.add_parser(name)
        command.add_argument("--case", type=Path, required=True)
        command.set_defaults(func=function)
        if name == "collect":
            command.add_argument("--screenshot", action="store_true")
            command.add_argument("--crash-file", action="append", default=[])
    command = commands.add_parser("analyze")
    command.add_argument("path", type=Path)
    command.set_defaults(func=analyze)
    args = parser.parse_args()
    try:
        args.func(args)
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
