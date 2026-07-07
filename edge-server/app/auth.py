"""Bearer-token auth for field nodes and dashboard/ops clients.

Two dependencies:
  * ``require_auth``  — accepts the shared **admin** token (dashboard / ops /
    provisioning) OR a valid **per-device** token issued via /hello. Use on
    data routes that any authenticated client may call.
  * ``require_admin`` — accepts ONLY the admin token. Use on operational /
    control routes (revoking a device, actuator commands, automation config).

In production this can be swapped for OAuth2 / JWT without changing route
signatures.
"""
import secrets

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials

from config import get_settings

security = HTTPBearer(auto_error=False)


def _bearer(credentials: HTTPAuthorizationCredentials | None) -> str:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing or invalid Authorization header. Use 'Bearer <token>'.",
        )
    return credentials.credentials


async def require_auth(
    request: Request,
    credentials: HTTPAuthorizationCredentials = Depends(security),
) -> str:
    settings = get_settings()
    token = _bearer(credentials)

    # 1) Shared admin token (dashboard / ops / device provisioning bootstrap).
    if secrets.compare_digest(token, settings.api_auth_token):
        return token

    # 2) Per-device token. Use the live cache singleton created at startup; if it
    #    is absent (some unit tests) or Redis is unreachable, fall through to a
    #    clean 403 rather than 500.
    cache = getattr(request.app.state, "cache", None)
    if cache is not None:
        try:
            node_id = await cache.verify_device_token(token)
            if node_id:
                return token
        except Exception:  # pragma: no cover - defensive: never 500 on auth
            pass

    raise HTTPException(
        status_code=status.HTTP_403_FORBIDDEN,
        detail="Invalid authentication token.",
    )


async def require_admin(
    credentials: HTTPAuthorizationCredentials = Depends(security),
) -> str:
    """Admin-token-only gate for operational / control endpoints."""
    settings = get_settings()
    token = _bearer(credentials)
    if not secrets.compare_digest(token, settings.api_auth_token):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Admin token required for this operation.",
        )
    return token
