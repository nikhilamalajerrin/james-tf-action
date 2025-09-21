FROM python:3.11-alpine

# tools + bash + jq + dos2unix (prevent CRLF issues)
RUN apk --no-cache add bash curl jq git ca-certificates dos2unix

# copy entrypoint and ensure it's executable & unix line endings
COPY entrypoint.sh /entrypoint.sh
RUN dos2unix /entrypoint.sh && chmod 0755 /entrypoint.sh

# run via bash to avoid shebang parsing issues on alpine
ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
