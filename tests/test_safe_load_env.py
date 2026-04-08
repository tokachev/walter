"""Tests for safe_load_env bash function (hooks/lib/safe-load-env.sh).

Each test writes a .env file to tmp_path, then runs:
  bash -c 'source .../safe-load-env.sh && safe_load_env "$1" && env' _ <path>
and inspects the captured environment.
"""

import os
import subprocess
from pathlib import Path

SAFE_LOAD_ENV_SH = Path(__file__).parent.parent / "hooks" / "lib" / "safe-load-env.sh"


def run_env(env_file: Path) -> dict[str, str]:
    """Source safe-load-env.sh, call safe_load_env on env_file, return exported env as dict."""
    script = (
        f'source {SAFE_LOAD_ENV_SH} && safe_load_env "$1" && env'
    )
    result = subprocess.run(
        ["bash", "-c", script, "_", str(env_file)],
        capture_output=True,
        text=True,
        # Deliberately clean environment so only vars exported by safe_load_env
        # (plus minimal PATH etc.) are present — easier to assert on.
        env={"PATH": os.environ.get("PATH", "/usr/bin:/bin")},
    )
    assert result.returncode == 0, f"bash exited {result.returncode}: {result.stderr}"
    env: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            env[k] = v
    return env


def test_command_injection_dollar_paren(tmp_path: Path) -> None:
    """$(...) must not be executed; EVIL must contain the literal string."""
    marker = tmp_path / "pwned-marker"
    env_file = tmp_path / ".env"
    env_file.write_text(f"EVIL=$(touch {marker})\n")

    captured = run_env(env_file)

    assert not marker.exists(), "command injection via $(...) was executed"
    # The literal value should be preserved as-is (unquoted, no inline # so comment
    # stripping won't fire; the $(...) is treated as plain text)
    assert "EVIL" in captured
    assert "touch" in captured["EVIL"], (
        f"Expected literal $(...) in EVIL, got: {captured['EVIL']!r}"
    )


def test_command_injection_backticks(tmp_path: Path) -> None:
    """Backtick expansion must not be executed; EVIL must contain the literal string."""
    marker = tmp_path / "pwned-marker-backtick"
    env_file = tmp_path / ".env"
    env_file.write_text(f"EVIL=`touch {marker}`\n")

    captured = run_env(env_file)

    assert not marker.exists(), "command injection via backticks was executed"
    assert "EVIL" in captured
    assert "touch" in captured["EVIL"], (
        f"Expected literal backtick command in EVIL, got: {captured['EVIL']!r}"
    )


def test_double_quoted_value_with_spaces(tmp_path: Path) -> None:
    """Double-quoted values should be stripped of surrounding quotes."""
    env_file = tmp_path / ".env"
    env_file.write_text('KEY="value with spaces"\n')

    captured = run_env(env_file)

    assert captured.get("KEY") == "value with spaces", (
        f"Expected 'value with spaces', got: {captured.get('KEY')!r}"
    )


# NOTE: safe_load_env DOES strip inline comments for unquoted values.
# The implementation uses: val="${val%% #*}" which removes ' # ...' suffix.
# So KEY=value # this is a comment → KEY=value  (comment stripped, trailing space trimmed).
def test_inline_comment_stripped(tmp_path: Path) -> None:
    """Inline comments on unquoted values are stripped (space + # + rest removed)."""
    env_file = tmp_path / ".env"
    env_file.write_text("KEY=value # this is a comment\n")

    captured = run_env(env_file)

    # Actual behavior: comment IS stripped by safe_load_env
    assert captured.get("KEY") == "value", (
        f"Expected 'value' (comment stripped), got: {captured.get('KEY')!r}"
    )


def test_malformed_lines_ignored(tmp_path: Path) -> None:
    """Malformed lines (no =, empty, whitespace-only) are silently ignored."""
    env_file = tmp_path / ".env"
    env_file.write_text(
        "\n"
        "   \n"
        "NOTASSIGNMENT\n"
        "123INVALID=bad\n"
        "GOOD=yes\n"
        "=nokey\n"
    )

    captured = run_env(env_file)

    assert captured.get("GOOD") == "yes"
    assert "NOTASSIGNMENT" not in captured
    assert "123INVALID" not in captured
    # =nokey has no key, regex won't match
    assert "" not in captured
