FROM elixir:1.10.0-alpine as build

# install build dependencies
RUN apk add --update git build-base

# prepare build dir
RUN mkdir /app
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# set build ENV
ENV MIX_ENV=prod

# install mix dependencies
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get
RUN mix deps.compile

# build project
COPY lib lib
RUN mix compile

# build release
RUN mix release

# prepare release image
FROM alpine:3.12 AS app
RUN apk add --update bash openssl

RUN mkdir /app
WORKDIR /app

COPY --from=build /app/_build/prod/rel/simple_plug_server ./
COPY --from=build /app/lib/simple_plug_server/entrypoint.sh ./simple_plug_server/entrypoint.sh
RUN chown -R nobody: /app
USER nobody

ENV HOME=/app

CMD ["bash", "./simple_plug_server/entrypoint.sh"]
