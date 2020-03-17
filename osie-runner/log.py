import os

import structlog

if os.getenv("LOG_RENDER_JSON"):
    renderer = structlog.processors.JSONRenderer()
else:
    try:
        import colorama  # noqa

        renderer = structlog.dev.ConsoleRenderer()
    except ImportError:
        renderer = structlog.dev.ConsoleRenderer(colors=False)

structlog.configure(
    processors=[
        structlog.stdlib.filter_by_level,
        structlog.stdlib.add_logger_name,
        structlog.stdlib.add_log_level,
        structlog.stdlib.PositionalArgumentsFormatter(),
        structlog.processors.StackInfoRenderer(),
        structlog.processors.format_exc_info,
        structlog.processors.UnicodeDecoder(),
        renderer,
    ],
    context_class=dict,
    logger_factory=structlog.stdlib.LoggerFactory(),
    wrapper_class=structlog.stdlib.BoundLogger,
    cache_logger_on_first_use=True,
)


def logger(logger):
    return structlog.get_logger(logger)
