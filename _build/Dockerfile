FROM klakegg/hugo:0.62.2-ext-alpine AS build

WORKDIR /workspace
COPY . /workspace
RUN hugo

FROM nginx:1

WORKDIR /app
COPY _deploy /app

COPY --from=build /workspace/public /app/site

CMD ["/app/start.sh"]
