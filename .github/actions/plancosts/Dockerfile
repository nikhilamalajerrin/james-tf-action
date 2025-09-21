FROM python:3.11-alpine

ARG TF_VERSION=1.6.6
# Tools needed by script + terraform unzip
RUN apk --no-cache add bash curl jq git unzip ca-certificates

# Install Terraform
RUN curl -fsSL "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip" -o /tmp/terraform.zip \
 && unzip /tmp/terraform.zip -d /usr/local/bin \
 && rm -f /tmp/terraform.zip \
 && terraform -version

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
