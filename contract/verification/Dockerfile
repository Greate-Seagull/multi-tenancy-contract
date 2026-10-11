FROM alpine/psql:18.6

USER root
RUN apk add --no-cache bash \
    && adduser -D -u 10001 psql

COPY --chmod=755 . /tests

USER 10001

WORKDIR /tests