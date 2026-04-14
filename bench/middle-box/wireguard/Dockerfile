# syntax=docker/dockerfile:1
FROM bench-common

RUN apt update -y && apt install -y iptables wireguard

ADD entrypoint.sh \
    /bench/

WORKDIR /bench/

ENTRYPOINT ./entrypoint.sh
