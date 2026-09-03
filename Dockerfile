FROM golang:1.27.0-alpine AS build

WORKDIR /go/src/github.com/segmentio/chamber
COPY . .

ARG TARGETARCH
ARG VERSION
RUN test -n "${VERSION}"

RUN apk add -U make ca-certificates
RUN make linux VERSION=${VERSION} TARGETARCH=${TARGETARCH}

# Assemble the final rootfs so it ships to ECR as a single layer.
RUN mkdir -p /rootfs/etc/ssl/certs && \
    cp /etc/ssl/certs/ca-certificates.crt /rootfs/etc/ssl/certs/ && \
    cp chamber /rootfs/chamber

FROM scratch AS run

COPY --from=build /rootfs/ /

ENTRYPOINT ["/chamber"]
