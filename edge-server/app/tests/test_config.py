"""Settings parsing tests."""
from config import Settings


def test_cors_origins_parsed_from_comma_string(monkeypatch):
    """CORS_ALLOW_ORIGINS is a comma-separated env string; pydantic-settings
    must not try to JSON-decode it (NoDecode) and the validator must split it."""
    monkeypatch.setenv(
        "CORS_ALLOW_ORIGINS", "https://plant-hub.local, http://localhost:8080"
    )
    settings = Settings()
    assert settings.cors_allow_origins == [
        "https://plant-hub.local",
        "http://localhost:8080",
    ]


def test_cors_origins_default_is_not_wildcard():
    settings = Settings()
    assert "*" not in settings.cors_allow_origins
