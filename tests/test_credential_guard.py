"""Tests for hooks/credential-guard.py.

credential-guard.py has a dash in its filename, so it cannot be imported via
plain `import`. We load it with importlib.util.spec_from_file_location.
"""

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

# ── Load the module ────────────────────────────────────────────────────────────

_HOOK_PATH = Path(__file__).parent.parent / "hooks" / "credential-guard.py"

spec = importlib.util.spec_from_file_location("credential_guard", _HOOK_PATH)
cg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cg)

# ── Helpers ────────────────────────────────────────────────────────────────────


def _findings(content: str):
    """Return cg.scan() result for convenience."""
    return cg.scan(content)


def _is_blocked(content: str) -> bool:
    return len(_findings(content)) > 0


def _invoke_via_subprocess(stdin_payload: str, mode: str = "write") -> dict:
    """Call the hook as a real subprocess and parse stdout JSON (or empty dict on allow)."""
    result = subprocess.run(
        [sys.executable, str(_HOOK_PATH), mode],
        input=stdin_payload,
        capture_output=True,
        text=True,
    )
    if result.stdout.strip():
        return json.loads(result.stdout)
    return {}


# ── False Positive tests (should ALLOW) ───────────────────────────────────────


class TestFalsePositives:
    """credential-guard must NOT flag these — legitimate content, no secrets."""

    def test_uuid(self):
        content = "Request ID: 550e8400-e29b-41d4-a716-446655440000"
        assert not _is_blocked(content), "UUID should not be flagged"

    def test_base64_log_blob(self):
        # 40-char base64 from a generic log message — not a known key prefix
        content = "Log payload: dGhpcyBpcyBqdXN0IGEgbG9nIG1lc3NhZ2U="
        assert not _is_blocked(content), "Generic base64 log blob should not be flagged"

    def test_git_commit_hash(self):
        content = "Merged commit a810ecb4c3f2e1b9d5f7a0c1e2d3f4a5b6c7d8e9"
        assert not _is_blocked(content), "Git commit hash should not be flagged"

    def test_lorem_ipsum(self):
        content = (
            "Lorem ipsum dolor sit amet, consectetur adipiscing elit. "
            "Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua."
        )
        assert not _is_blocked(content), "Lorem ipsum should not be flagged"

    def test_doc_placeholder(self):
        content = "Set API_KEY=your-key-here in your environment before running."
        assert not _is_blocked(content), "Doc placeholder should not be flagged"


# ── True Positive tests (should DENY/block) ───────────────────────────────────


class TestTruePositives:
    """credential-guard MUST flag these — real-looking secrets."""

    def test_aws_secret_access_key(self):
        content = "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        findings = _findings(content)
        assert findings, "AWS Secret Access Key must be flagged"
        descs = [d for d, _ in findings]
        assert any("AWS" in d for d in descs)

    def test_pem_private_key(self):
        content = (
            "-----BEGIN RSA PRIVATE KEY-----\n"
            "MIIEowIBAAKCAQEA2a2rwplBQLF29amygykEMmYz0+Kcj3bKBp29nWqKb/5TASal\n"
            "-----END RSA PRIVATE KEY-----"
        )
        findings = _findings(content)
        assert findings, "PEM private key header must be flagged"
        descs = [d for d, _ in findings]
        assert any("Private key" in d for d in descs)

    def test_github_pat(self):
        content = "token: ghp_A1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6Q7R8"
        findings = _findings(content)
        assert findings, "GitHub PAT must be flagged"
        descs = [d for d, _ in findings]
        assert any("GitHub" in d for d in descs)

    def test_openai_api_key(self):
        # sk- + 48 alphanumeric chars  (pattern: sk-[A-Za-z0-9]{20,})
        content = "OPENAI_API_KEY=sk-" + "A" * 48
        findings = _findings(content)
        assert findings, "OpenAI API key must be flagged"
        descs = [d for d, _ in findings]
        assert any("OpenAI" in d or "secret" in d.lower() for d in descs)

    def test_slack_bot_token(self):
        # Pattern: xox[bporas]-[0-9]{10,}-[0-9a-zA-Z]{20,}  (two segments after prefix)
        # Token constructed from pieces to avoid tripping GitHub's secret scanner.
        content = "slack_token = " + "xoxb-" + "1" * 11 + "-" + "a" * 24
        findings = _findings(content)
        assert findings, "Slack bot token must be flagged"
        descs = [d for d, _ in findings]
        assert any("Slack" in d for d in descs)


# ── Fail-open test ─────────────────────────────────────────────────────────────


class TestFailOpen:
    """Malformed or crashing input must NOT block — the hook must fail open."""

    def test_malformed_json_does_not_crash(self):
        """Pass unparseable JSON on stdin; subprocess must exit 0 with no denial output."""
        result = subprocess.run(
            [sys.executable, str(_HOOK_PATH), "write"],
            input="THIS IS NOT JSON {{{",
            capture_output=True,
            text=True,
        )
        # exit 0 means allow
        assert result.returncode == 0, "Hook must exit 0 (fail-open) on malformed JSON"
        # No denial JSON in stdout
        assert not result.stdout.strip(), (
            "Hook must produce no output on crash (fail-open, not deny)"
        )

    def test_missing_tool_input_does_not_crash(self):
        """Valid JSON but missing tool_input key — should silently allow."""
        payload = json.dumps({"session_id": "test", "tool_name": "Write"})
        result = _invoke_via_subprocess(payload, mode="write")
        # Empty dict means allow (no denial JSON)
        assert result == {}, "Missing tool_input must not produce a denial"

    def test_empty_content_does_not_block(self):
        """Empty string content must not produce any findings."""
        findings = _findings("")
        assert findings == [], "Empty content must produce no findings"
