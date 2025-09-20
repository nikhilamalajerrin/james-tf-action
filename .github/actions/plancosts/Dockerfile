FROM python:3.11-alpine

RUN apk --no-cache add bash curl jq git ca-certificates build-base dos2unix

COPY entrypoint.sh /entrypoint.sh
# normalize line endings + strip UTF-8 BOM (if any) + make executable
RUN dos2unix /entrypoint.sh \
 && sed -i '1s/^\xEF\xBB\xBF//' /entrypoint.sh \
 && chmod 0755 /entrypoint.sh

# invoke via bash to avoid kernel trying to execute the script directly
ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
