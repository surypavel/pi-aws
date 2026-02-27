FROM golang:1.23-alpine AS build
WORKDIR /app
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -o git-proxy .

FROM alpine:3.19
COPY --from=build /app/git-proxy /git-proxy
ENTRYPOINT ["/git-proxy"]
