# syntax=docker/dockerfile:1
# Synapse plus Zuno's modules. Built and pushed by
# .github/workflows/synapse-image.yml; docker-compose.yml runs its latest
# tag. Each module ships as a FROM scratch image holding only its wheel,
# published by that module's own CI on a v* tag; bump the tag here to upgrade.
# The wheels are bind-mounted for the install, so no layer carries them.
FROM ghcr.io/zuno-chat/zuno-calls-wheel:v0.1.0 AS zuno-calls
FROM ghcr.io/zuno-chat/zuno-register-wheel:v0.1.0 AS zuno-register
FROM ghcr.io/zuno-chat/zuno-push-wheel:v0.1.0 AS zuno-push
FROM ghcr.io/element-hq/synapse:v1.161.0
RUN --mount=type=bind,from=zuno-calls,target=/wheels/zuno-calls \
    --mount=type=bind,from=zuno-register,target=/wheels/zuno-register \
    --mount=type=bind,from=zuno-push,target=/wheels/zuno-push \
    pip install --no-cache-dir /wheels/zuno-calls/*.whl /wheels/zuno-register/*.whl \
      /wheels/zuno-push/*.whl \
 && python -c "import zuno_calls, zuno_register, zuno_push"
