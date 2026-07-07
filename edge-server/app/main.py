"""FastAPI application factory."""
import asyncio
import logging
from contextlib import asynccontextmanager

import structlog

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from slowapi.errors import RateLimitExceeded
from slowapi.middleware import SlowAPIMiddleware
from starlette.responses import JSONResponse

from config import get_settings
from routes import limiter, router
from services import (
    AgronomistChat,
    AlertEngine,
    Cache,
    ControlEngine,
    InferenceEngine,
    MQTTSubscriber,
    MqttPublisher,
    TimeSeriesDB,
)


def configure_logging() -> None:
    structlog.configure(
        processors=[
            structlog.contextvars.merge_contextvars,
            structlog.processors.add_log_level,
            structlog.processors.TimeStamper(fmt="iso"),
            structlog.processors.dict_tracebacks,
            structlog.processors.JSONRenderer(),
        ],
        wrapper_class=structlog.make_filtering_bound_logger(
            getattr(logging, get_settings().log_level)
        ),
        context_class=dict,
        logger_factory=structlog.PrintLoggerFactory(),
        cache_logger_on_first_use=True,
    )


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Create heavyweight service singletons once at startup.

    The ONNX inference session, Redis client, InfluxDB client, and cloud chat
    client are expensive to construct. Building them per-request (the previous
    behaviour) reparsed and recompiled the model graph on every /analyze call,
    which could cost more than the inference itself. They are created here and
    reused for the process lifetime.
    """
    logger = structlog.get_logger()
    settings = get_settings()

    app.state.cache = Cache(settings)
    app.state.inference = InferenceEngine(settings)
    app.state.chat = AgronomistChat(settings)
    try:
        app.state.tsdb = TimeSeriesDB(settings)
    except Exception as exc:  # pragma: no cover - depends on external service
        logger.error("tsdb_init_failed", error=str(exc))
        app.state.tsdb = None

    # MQTT subscriber — bridges soil-node telemetry into Redis/InfluxDB.
    # Non-fatal: if the broker is unreachable (tests, dev without Mosquitto)
    # the subscriber logs a warning and HTTP telemetry continues working.
    app.state.mqtt_sub = MQTTSubscriber(
        settings,
        app.state.cache,
        getattr(app.state, "tsdb", None),
        asyncio.get_running_loop(),
    )
    app.state.mqtt_sub.start()

    # Alert engine — periodic scan for offline nodes + out-of-range telemetry.
    app.state.alert_engine = AlertEngine(settings, app.state.cache)
    app.state.alert_engine.start()

    # Outbound MQTT for actuator commands + closed-loop control engine.
    app.state.mqtt_pub = MqttPublisher(settings)
    app.state.mqtt_pub.start()
    app.state.control_engine = ControlEngine(
        settings, app.state.cache, app.state.mqtt_pub
    )
    app.state.control_engine.start()

    logger.info("api_startup", version="1.0.0", log_level=settings.log_level)
    yield

    await app.state.control_engine.stop()
    app.state.mqtt_pub.stop()
    await app.state.alert_engine.stop()
    app.state.mqtt_sub.stop()
    if getattr(app.state, "tsdb", None) is not None:
        app.state.tsdb.close()
    logger.info("api_shutdown")


def create_app() -> FastAPI:
    configure_logging()
    settings = get_settings()

    app = FastAPI(
        title="Industrial AI Agronomist Server",
        version="1.0.0",
        docs_url="/docs" if settings.log_level == "DEBUG" else None,
        redoc_url="/redoc" if settings.log_level == "DEBUG" else None,
        lifespan=lifespan,
    )

    app.state.limiter = limiter
    app.add_middleware(SlowAPIMiddleware)
    # Bearer tokens are sent in the Authorization header (not cookies), so CORS
    # credentials mode is unnecessary and the origin list is explicit rather than
    # a wildcard. "*" + credentials is an invalid/unsafe combination.
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_allow_origins,
        allow_credentials=False,
        allow_methods=["GET", "POST"],
        allow_headers=["Authorization", "Content-Type"],
    )

    @app.exception_handler(RateLimitExceeded)
    async def rate_limit_handler(request, exc):  # noqa: ARG001
        return JSONResponse(
            status_code=429,
            content={"detail": "Rate limit exceeded. Slow down."},
        )

    app.include_router(router)

    return app


app = create_app()
