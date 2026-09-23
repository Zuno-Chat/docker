# syntax=docker/dockerfile:1
# Synapse plus Zuno's modules. Built and pushed by
# .github/workflows/synapse-image.yml; docker-compose.yml pins the result by
# sha tag. Each module ships as a FROM scratch image holding only its wheel,
# published by that module's own CI on a v* tag; bump the tag here to upgrade.
# The wheel is bind-mounted for the install, so no layer carries it.
FROM ghcr.io/zuno-chat/zuno-calls-wheel:v0.1.0 AS zuno-calls
FROM ghcr.io/element-hq/synapse:v1.161.0
RUN --mount=type=bind,from=zuno-calls,target=/wheels \
    pip install --no-cache-dir /wheels/*.whl \
 && python -c "import zuno_calls"
