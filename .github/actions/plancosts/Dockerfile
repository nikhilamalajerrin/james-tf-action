FROM python:3.11-alpine

# Basics + CRLF fixer
RUN apk --no-cache add bash curl jq git ca-certificates build-base dos2unix

# (Optional) enable real Terraform runs by uncommenting this block AND setting USE_TFDIR=1 in entrypoint env.
# RUN apk --no-cache add wget unzip \
#   && TERRAFORM_VERSION=1.6.6 \
#   && wget -O /tmp/terraform.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
#   && unzip /tmp/terraform.zip -d /usr/local/bin \
#   && rm -f /tmp/terraform.zip

COPY entrypoint.sh /entrypoint.sh
RUN dos2unix /entrypoint.sh && chmod 0755 /entrypoint.sh

ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
