FROM python:3.11-alpine

RUN apk --no-cache add bash curl jq git ca-certificates build-base

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
