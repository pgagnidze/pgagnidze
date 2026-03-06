FROM nickblah/luajit:2.1-luarocks-alpine

WORKDIR /app

RUN apk add --no-cache git gcc make musl-dev linux-headers \
    && luarocks install mote 0.1.5 \
    && apk del git gcc make linux-headers

COPY . .

EXPOSE 8080

CMD ["luajit", "main.lua"]
