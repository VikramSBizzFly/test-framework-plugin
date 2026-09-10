# Copied into the target project only after Tier 1 detection confirms
# pytest-playwright is already installed (`pip show pytest-playwright`).
# This framework never runs `pip install` on your behalf.
import json
from pathlib import Path

import pytest

CREDS = json.loads(Path("tests/credentials.json").read_text())


@pytest.fixture(scope="session")
def base_url():
    # Overrides pytest-playwright's own base_url fixture. base_url lives in
    # tests/credentials.json, never hardcoded here, so the same specs run
    # against every environment a role's session was captured for.
    return CREDS["base_url"]


@pytest.fixture
def role():
    # Generated specs override this fixture per module (see
    # skills/test-codegen/references/python.md) rather than logging in.
    return "admin"


@pytest.fixture
def browser_context_args(browser_context_args, role):
    # This is where storage state gets applied — pytest-playwright builds its
    # `context` fixture from these args, so overriding it here is enough to
    # reuse a saved session with no login step anywhere in a spec.
    state_file = Path(f"tests/.auth/{role}.json")
    if not state_file.exists():
        pytest.skip(f"no saved session for role '{role}' — run /test-auth {role}")
    return {**browser_context_args, "base_url": CREDS["base_url"], "storage_state": str(state_file)}
