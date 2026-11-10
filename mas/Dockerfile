# syntax=docker/dockerfile:1
FROM ghcr.io/element-hq/matrix-authentication-service:1.28.0-debug AS mas

FROM --platform=$BUILDPLATFORM alpine:3.24 AS theme
RUN apk add --no-cache jq
COPY --from=mas /usr/local/share/mas-cli /upstream
COPY theme /theme
RUN sh /theme/apply.sh /upstream /theme /out

FROM mas
COPY --from=theme /out/ /usr/local/share/mas-cli/
RUN ["/busybox/env", "MAS_MATRIX_SECRET=templates-check", "mas-cli", "templates", "check"]
