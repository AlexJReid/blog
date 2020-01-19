#!/bin/bash

[[ -z "$PORT" ]] && export PORT=8080
envsubst '$PORT' < /app/nginx.conf.include > /app/nginx.conf

exec nginx -c /app/nginx.conf
