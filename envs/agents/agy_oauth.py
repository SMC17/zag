"""Harbor agent: Antigravity CLI (agy) authenticated with your own agy sign-in, not an API key.

Harbor's built-in `antigravity-cli` agent needs GEMINI_API_KEY. This subclass instead copies the
OAuth token that agy itself stores into the trial container, the same way Harbor's Codex agent
can reuse ~/.codex/auth.json.

Where the token lives:
- On macOS, agy keeps it in the login keychain (service "gemini", account "antigravity").
  `envs/scripts/agy_token.sh` exports it to a 0600 file on the host.
- On Linux without a desktop keyring, agy reads ~/.gemini/antigravity-cli/antigravity-oauth-token
  (found by tracing agy 1.5.13). This agent writes the token there, mode 0600, before agy runs.

The token file path on the host comes from AGY_OAUTH_TOKEN_FILE
(default ~/.config/smc17-envs/agy-oauth-token). Use: -a agy_oauth:AgyOAuth with envs/agents on
PYTHONPATH (run_agents.py does this for you).
"""
import os
import shlex
from pathlib import Path
from typing import Any

from harbor.agents.installed.antigravity_cli import AntigravityCli
from harbor.environments.base import BaseEnvironment

DEFAULT_TOKEN = Path.home() / ".config" / "smc17-envs" / "agy-oauth-token"
CONTAINER_TOKEN = "$HOME/.gemini/antigravity-cli/antigravity-oauth-token"


class AgyOAuth(AntigravityCli):
    @staticmethod
    def name() -> str:
        return "agy-oauth"

    @classmethod
    def check_model_credentials(cls, connection, *, kwargs, env, explicit_env=None):
        path = Path(env.get("AGY_OAUTH_TOKEN_FILE") or DEFAULT_TOKEN)
        if not path.is_file():
            raise ValueError(f"agy-oauth: no token file at {path}; run envs/scripts/agy_token.sh")

    def _resolve_api_key(self) -> str:
        # No API key: agy authenticates with the uploaded OAuth token. An empty value keeps
        # the base class from writing modelProvider=gemini into settings.json.
        return ""

    async def install(self, environment: BaseEnvironment) -> None:
        await super().install(environment)
        token = Path(self._get_env("AGY_OAUTH_TOKEN_FILE") or DEFAULT_TOKEN)
        await environment.upload_file(str(token), "/tmp/agy-oauth-token")
        await self.exec_as_root(environment, command="chmod 644 /tmp/agy-oauth-token")
        await self.exec_as_agent(
            environment,
            command=(
                f"install -D -m 600 /tmp/agy-oauth-token {CONTAINER_TOKEN} && "
                "rm -f /tmp/agy-oauth-token 2>/dev/null || true"
            ),
        )
        await self.exec_as_root(environment, command="rm -f /tmp/agy-oauth-token")
