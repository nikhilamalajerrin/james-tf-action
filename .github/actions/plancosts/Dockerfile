# .github/actions/plancosts/Dockerfile
FROM python:3.11-alpine

# Install system dependencies
RUN apk --no-cache add \
      bash curl jq git ca-certificates build-base

# Just copy the entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]