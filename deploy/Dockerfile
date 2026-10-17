# Container image of the BWCE AI Generator.
#
# 1. Build the Linux executable with your licensed TIBCO Flogo tooling (the free VS Code edition only builds for the
#    local machine), e.g. into build/:
#      fcli build-exe -f bwce-ai-generator-github.flogo -c <context> -p linux/amd64 -n bwce-ai-generator-github -o build
# 2. From the repository root:
#      docker build -f deploy/Dockerfile -t <registry>/bwce-ai-generator:1.0.0 .
# 3. Run it with your settings (see deploy/config.env.example and deploy/secrets.env.example):
#      docker run -d -p 9999:9999 -p 8081:8081 --env-file deploy/config.env --env-file deploy/secrets.env <image>
FROM alpine:3.20

RUN apk add --no-cache ca-certificates tzdata \
    && adduser -D -H -u 10001 flogo

# The app reads config/, rules/ and static/ relative to its working directory and writes the PostgreSQL CA
# certificate there when TLS is on, so the directory belongs to the app user.
WORKDIR /app
COPY --chown=10001:10001 config/ config/
COPY --chown=10001:10001 rules/ rules/
COPY --chown=10001:10001 static/ static/
COPY --chown=10001:10001 --chmod=0755 build/bwce-ai-generator-github ./
RUN chown 10001:10001 /app

USER 10001
ENV FLOGO_APP_PROPS_ENV=auto \
    FLOGO_EXPOSE_SWAGGER_EP=true
EXPOSE 9999 8081
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
    CMD wget -q -O /dev/null http://127.0.0.1:9999/health || exit 1
ENTRYPOINT ["./bwce-ai-generator-github"]
