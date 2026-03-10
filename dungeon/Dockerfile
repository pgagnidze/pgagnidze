FROM docker.io/nickblah/luajit:2.1-luarocks-alpine

WORKDIR /app

RUN apk add --no-cache git gcc musl-dev linux-headers \
    && luarocks install mote 0.1.6 \
    && apk del git gcc musl-dev linux-headers

COPY . .

EXPOSE 8080

CMD ["luajit", "main.lua"]
