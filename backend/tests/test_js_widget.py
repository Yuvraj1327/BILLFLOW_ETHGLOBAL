"""Runs the Node test suites for the checkout widget (billflow.js), the Node SDK and the demo merchant as part of pytest."""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
NODE = shutil.which("node")
pytestmark = pytest.mark.skipif(NODE is None, reason="node >= 18 not installed")


def _run(*args: str, cwd: Path) -> None:
    r = subprocess.run([NODE, "--test", *args], cwd=cwd, capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, r.stdout[-3000:] + r.stderr[-1000:]


def test_widget_unit_tests():
    _run("tests/js/widget.test.js", "tests/js/widget_ui.test.js", cwd=ROOT / "backend")


def test_sdk_and_demo_merchant_tests():
    _run("test/webhook.test.js", cwd=ROOT / "demo-merchant")
