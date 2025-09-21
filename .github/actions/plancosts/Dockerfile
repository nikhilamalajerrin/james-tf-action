FROM python:3.11-alpine

# Basics + CRLF fixer
RUN apk --no-cache add bash curl jq git ca-certificates build-base dos2unix

COPY entrypoint.sh /entrypoint.sh
RUN dos2unix /entrypoint.sh && chmod 0755 /entrypoint.sh

# Call via bash so the shebang never bites us
ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
