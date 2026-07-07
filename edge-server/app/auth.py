"""Bearer-token auth returning a scoped Principal.

Two dependencies:
  * ``require_auth``  — accepts the shared **admin** token (dashboard / ops /
    provisioning) OR a valid **per-device** token issued via /hello. Returns a
    ``Principal`` so routes can check *which* device is calling.
  * ``require_admin`` — accepts ONLY the admin token. Use on operational /
    control routes (revoking a device, actuator commands, automation config).

A device principal may only act on its own node_id — node-scoped write routes
enforce this via ``principal.assert_node(node_id)``.

In production this can be swapped for OAuth2 / JWT without changing route
signatures.
"""
import secrets
from dataclasses import dataclass
from typing import Literal

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials

from config import get_settings

security = HTTPBearer(auto_error=False)


@dataclass(frozen=True)
class Principal:
    kind: Literal["admin", "device"]
    node_id: str | None = None

    @property
    def is_admin(self) -> bool:
        return self.kind == "admin"

    def assert_node(self, node_id: str) -> None:
        """403 unless admin or the device that owns ``node_id``."""
        if self.is_admin or self.node_id == node_id:
            return
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Token is not authorized for this node.",
        )


def _bearer(credentials: HTTPAuthorizationCredentials | None) -> str:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing or invalid Authorization header. Use 'Bearer <token>'.",
        )
    token = credentials.credentials.strip()
    if not token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Empty bearer token.",
        )
    return token


async def require_auth(
    request: Request,
    credentials: HTTPAuthorizationCredentials = Depends(security),
) -> Principal:
    settings = get_settings()
    token = _bearer(credentials)

    # 1) Shared admin token (dashboard / ops / device provisioning bootstrap).
    if secrets.compare_digest(token, settings.api_auth_token):
        return Principal(kind="admin")

    # 2) Per-device token. Use the live cache singleton created at startup; if it
    #    is absent (some unit tests) or Redis is unreachable, fall through to a
    #    clean 403 rather than 500.
    cache = getattr(request.app.state, "cache", None)
    if cache is not None:
        try:
            node_id = await cache.verify_device_token(token)
            if node_id:
                return Principal(kind="device", node_id=node_id)
        except Exception:  # pragma: no cover - defensive: never 500 on auth
            pass

    raise HTTPException(
        status_code=status.HTTP_403_FORBIDDEN,
        detail="Invalid authentication token.",
    )


async def require_admin(
    credentials: HTTPAuthorizationCredentials = Depends(security),
) -> Principal:
    """Admin-token-only gate for operational / control endpoints."""
    settings = get_settings()
    token = _bearer(credentials)
    if not secrets.compare_digest(token, settings.api_auth_token):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Admin token required for this operation.",
        )
    return Principal(kind="admin")
