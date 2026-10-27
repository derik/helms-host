"""Offline runner behavior: fake Docker, real temporary storage, no downloads."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODEL = "unsloth/Qwen3.5-35B-A3B-GGUF:UD-Q4_K_XL"


class HelmsHostTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.service = self.root / "checkout with spaces/helms-host"
        self.service.mkdir(parents=True)
        for name in ["ctl.sh", "Dockerfile"]:
            shutil.copy2(ROOT / name, self.service / name)
        self.calls = self.root / "calls.jsonl"
        self.models = self.root / "storage with spaces/models"
        binary = self.root / "bin"
        binary.mkdir()
        docker = binary / "docker"
        docker.write_text('''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
record = {"args": args}
if args[0] == "build":
    record["dockerfile"] = sys.stdin.read()
with open(os.environ["HELMS_HOST_TEST_CALLS"], "a") as f:
    f.write(json.dumps(record) + "\\n")
if args[0] == "info" and os.environ.get("HELMS_HOST_TEST_DAEMON_FAIL"):
    sys.exit(1)
if args[:2] == ["container", "inspect"]:
    if "HELMS_HOST_TEST_OWNER" not in os.environ and "HELMS_HOST_TEST_LABELS" not in os.environ:
        sys.exit(1)
    labels = json.loads(os.environ.get("HELMS_HOST_TEST_LABELS", "{}"))
    if "HELMS_HOST_TEST_OWNER" in os.environ:
        labels["io.helms-host.service"] = os.environ["HELMS_HOST_TEST_OWNER"]
    if args[3] == '{{with index .Config.Labels "io.helms-host.service"}}{{.}}{{end}}':
        print(labels.get("io.helms-host.service", ""))
    elif args[3] == '{{range $key, $value := .Config.Labels}}{{if eq $value "helms-host"}}{{println $key}}{{end}}{{end}}':
        for key, value in labels.items():
            if value == "helms-host": print(key)
    else:
        raise AssertionError("Unexpected ownership template: " + args[3])
if args[:2] == ["image", "inspect"] and not os.environ.get("HELMS_HOST_TEST_IMAGE"):
    sys.exit(1)
if args[0] == "build" and os.environ.get("HELMS_HOST_TEST_BUILD_FAIL"):
    sys.exit(1)
if args[0] == "run": print("fake-container-id")
''')
        docker.chmod(0o755)
        # Use only an explicit environment so the operator's config is irrelevant.
        self.env = {
            "PATH": str(binary) + os.pathsep + os.environ["PATH"],
            "HELMS_HOST_TEST_CALLS": str(self.calls),
            "LLAMA_MODELS_DIR": str(self.models),
            "LLAMA_STORAGE_MOUNT": "",
        }

    def ctl(self, *args, ok=True):
        result = subprocess.run([str(self.service / "ctl.sh"), *args], cwd=self.root,
                                env=self.env, text=True, capture_output=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def records(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def commands(self):
        return [record["args"] for record in self.records()]

    def test_named_run_builds_without_local_context_and_preserves_cached_weights(self):
        cache = self.models / "cache"
        cache.mkdir(parents=True)
        weight = cache / "existing.gguf"
        weight.write_bytes(b"preserve cached weights")
        before = weight.stat()
        result = self.ctl("run", "--model", MODEL, "--alias", "qwen3.5-35b-a3b",
                          "--mode", "opencode", "--", "--temp", "0.6")
        records = self.records()
        build = next(r for r in records if r["args"][0] == "build")
        self.assertEqual(build["args"][-1], "-")
        self.assertEqual(build["dockerfile"], (self.service / "Dockerfile").read_text())
        run = next(r["args"] for r in records if r["args"][0] == "run")
        self.assertEqual(run[run.index("-hf") + 1], MODEL)
        self.assertEqual(run[run.index("--alias") + 1], "qwen3.5-35b-a3b")
        self.assertIn("--no-ui", run)
        self.assertIn("io.helms-host.service=helms-host", run)
        self.assertIn(f"type=bind,source={self.models},target=/models", run)
        self.assertIn("LLAMA_CACHE=/models/cache", run)
        self.assertEqual(run[-2:], ["--temp", "0.6"])
        self.assertIn("may still be downloading/loading", result.stdout)
        after = weight.stat()
        self.assertEqual((before.st_ino, before.st_mtime_ns, before.st_size),
                         (after.st_ino, after.st_mtime_ns, after.st_size))
        self.assertEqual(weight.read_bytes(), b"preserve cached weights")
        self.assertFalse((self.service / ".env").exists())
        self.assertFalse((self.service / ".run.env").exists())

    def test_env_precedence_webui_equals_flags_relative_paths_and_image_reuse(self):
        del self.env["LLAMA_MODELS_DIR"]
        settings = 'LLAMA_MODELS_DIR="models with spaces"\nHOST_PORT=9999\nCTX_SIZE=4096\n'
        (self.service / ".env").write_text(settings)
        (self.root / ".env").write_text("HOST_PORT=1\n")  # Ignore unrelated cwd.
        self.env.update(HOST_PORT="8888", HELMS_HOST_TEST_IMAGE="1")
        self.ctl("run", "--model=" + MODEL, "--mode=webui", "--ctx-size=8192")
        run = self.commands()[-1]
        self.assertIn("--ui", run)
        self.assertIn("8888:8080", run)
        self.assertEqual(run[run.index("--ctx-size") + 1], "8192")
        self.assertEqual(run[run.index("--alias") + 1], "Qwen3.5-35B-A3B-GGUF")
        self.assertIn(f"type=bind,source={self.service}/models with spaces,target=/models", run)
        self.assertFalse(any(c[0] == "build" for c in self.commands()))
        self.assertEqual((self.service / ".env").read_text(), settings)

    def test_invalid_arguments_fail_before_docker_or_storage(self):
        for args in [("run",), ("run", "--model"), ("run", "--model", "--mode", "webui"),
                     ("run", "--model", MODEL, "--mode", "wrong"),
                     ("run", "--model", MODEL, "--port=65536"),
                     ("run", "--model", MODEL, "--ctx-size=0"),
                     ("run", "--model", MODEL, "--unknown"), ("stop", "--model", MODEL)]:
            with self.subTest(args=args):
                self.ctl(*args, ok=False)
        self.assertEqual(self.commands(), [])
        self.assertFalse(self.models.exists())

    def test_unmounted_drive_and_symlink_escape_fail_before_any_mutation(self):
        drive = self.root / "unmounted drive"
        drive.mkdir()
        self.env.update(LLAMA_STORAGE_MOUNT=str(drive), LLAMA_MODELS_DIR=str(drive / "models"))
        self.assertIn("not mounted", self.ctl("run", "--model", MODEL, ok=False).stderr)
        self.assertFalse((drive / "models").exists())
        self.assertEqual(self.commands(), [])
        # /proc is an actual mount; a cache symlink escapes it onto temp storage.
        self.models.mkdir(parents=True)
        (self.models / "cache").symlink_to("/proc", target_is_directory=True)
        self.env.update(LLAMA_STORAGE_MOUNT="/", LLAMA_MODELS_DIR=str(self.models))
        self.assertIn("different filesystem", self.ctl("run", "--model", MODEL, ok=False).stderr)
        self.assertFalse((self.models / ".home").exists())
        self.assertEqual(self.commands(), [])

    def test_container_collision_and_failed_build_preserve_current_container(self):
        self.env.update(HELMS_HOST_TEST_OWNER="another-project")
        self.assertIn("not identified as Helm's Host", self.ctl("run", "--model", MODEL, ok=False).stderr)
        self.assertFalse(any(c[0] in ["build", "run"] or c[:2] == ["container", "rm"] for c in self.commands()))
        self.assertFalse(self.models.exists())
        self.calls.unlink()
        self.env.update(HELMS_HOST_TEST_OWNER="helms-host", HELMS_HOST_TEST_BUILD_FAIL="1")
        self.ctl("run", "--model", MODEL, ok=False)
        self.assertFalse(any(c[0] == "run" or c[:2] == ["container", "rm"] for c in self.commands()))
        self.assertFalse(self.models.exists())

    def test_daemon_failure_does_not_create_storage(self):
        self.env["HELMS_HOST_TEST_DAEMON_FAIL"] = "1"
        self.ctl("run", "--model", MODEL, ok=False)
        self.assertEqual(self.commands(), [["info"]])
        self.assertFalse(self.models.exists())

    def test_stop_only_removes_owned_container_and_never_storage(self):
        self.models.mkdir(parents=True)
        self.env["HELMS_HOST_TEST_OWNER"] = "helms-host"
        self.ctl("stop")
        self.assertEqual(self.commands()[-1], ["container", "rm", "--force", "local-helms-host"])
        self.assertTrue(self.models.is_dir())
        self.calls.unlink()
        self.env["HELMS_HOST_TEST_OWNER"] = "another-project"
        self.ctl("stop", ok=False)
        self.assertFalse(any(c[:2] == ["container", "rm"] for c in self.commands()))

    def test_env_values_are_literal_and_cli_port_wins(self):
        (self.service / ".env").write_text('HF_TOKEN="$(touch sentinel)"\nHOST_PORT=9000\n')
        self.ctl("run", "--model", MODEL, "--port", "8082")
        self.assertIn("8082:8080", self.commands()[-1])
        self.assertFalse((self.root / "sentinel").exists())
        self.assertNotIn("$(touch sentinel)", self.calls.read_text())

    def test_status_checks_ownership_before_showing_container(self):
        self.env["HELMS_HOST_TEST_OWNER"] = "helms-host"
        self.ctl("status")
        status = self.commands()[-1]
        self.assertIn("name=^/local-helms-host$", status)
        self.assertEqual(self.commands()[1][:2], ["container", "inspect"])

    def test_earlier_service_label_supports_run_stop_logs_and_status_without_data_loss(self):
        self.env["HELMS_HOST_TEST_LABELS"] = json.dumps({"io.previous-version.service": "helms-host"})
        cache = self.models / "cache"
        cache.mkdir(parents=True)
        weight = cache / "existing.gguf"
        weight.write_bytes(b"keep this model")
        before = weight.stat()
        for args in [("run", "--model", MODEL), ("stop",), ("logs",), ("status",)]:
            with self.subTest(args=args):
                self.calls.unlink(missing_ok=True)
                self.ctl(*args)
                commands = self.commands()
                if args[0] == "run":
                    remove = next(i for i, call in enumerate(commands) if call[:2] == ["container", "rm"])
                    run = next(i for i, call in enumerate(commands) if call[0] == "run")
                    self.assertLess(remove, run)
                    self.assertIn("io.helms-host.service=helms-host", commands[run])
                elif args[0] == "stop":
                    self.assertEqual(commands[-1][:2], ["container", "rm"])
                elif args[0] == "logs":
                    self.assertEqual(commands[-1][0], "logs")
                else:
                    self.assertEqual(commands[-1][0], "ps")
                    self.assertNotIn("label=io.helms-host.service=helms-host", commands[-1])
        after = weight.stat()
        self.assertEqual((before.st_ino, before.st_mtime_ns, before.st_size),
                         (after.st_ino, after.st_mtime_ns, after.st_size))
        self.assertEqual(weight.read_bytes(), b"keep this model")

    def test_missing_unrelated_or_conflicting_labels_cannot_bypass_ownership(self):
        for labels in [{}, {"io.other.service": "another-project"},
                       {"org.opencontainers.image.title": "helms-host"},
                       {"io.helms-host.service": "another-project", "io.previous-version.service": "helms-host"}]:
            self.env["HELMS_HOST_TEST_LABELS"] = json.dumps(labels)
            for args in [("run", "--model", MODEL), ("stop",), ("logs",), ("status",)]:
                with self.subTest(labels=labels, args=args):
                    self.calls.unlink(missing_ok=True)
                    result = self.ctl(*args, ok=False)
                    self.assertIn("not identified as Helm's Host", result.stderr)
                    self.assertTrue(all(call[0] == "info" or call[:2] == ["container", "inspect"]
                                        for call in self.commands()))
                    self.assertFalse(self.models.exists())


if __name__ == "__main__":
    unittest.main()
