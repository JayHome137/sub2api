ARG NODE_IMAGE=node:20-alpine
ARG NGINX_IMAGE=nginx:1.27-alpine

FROM ${NODE_IMAGE} AS frontend-builder

WORKDIR /workspace

RUN corepack enable && corepack prepare pnpm@10.28.2 --activate

COPY frontend/package.json frontend/pnpm-lock.yaml frontend/pnpm-workspace.yaml frontend/.npmrc frontend/
RUN cd frontend && pnpm install --frozen-lockfile

COPY frontend/ frontend/
COPY docs/legal/ docs/legal/

RUN mkdir -p backend/internal/web/dist \
    && cd frontend \
    && pnpm run build

FROM ${NGINX_IMAGE}

ARG BUILD_VERSION=dev
ARG VCS_REF=unknown

LABEL org.opencontainers.image.title="AIFoo Sub2API frontend" \
      org.opencontainers.image.description="Source-integrated AIFoo UI and public landing pages for Sub2API" \
      org.opencontainers.image.source="https://github.com/JayHome137/sub2api" \
      org.opencontainers.image.version="${BUILD_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}"

COPY --from=frontend-builder /workspace/backend/internal/web/dist/ /usr/share/nginx/html/
RUN mv /usr/share/nginx/html/index.html /usr/share/nginx/html/app.html

COPY deploy/frontend/landing/ /usr/share/nginx/html/
COPY deploy/frontend/security-headers.conf /etc/nginx/snippets/aifoo-security-headers.conf
COPY deploy/frontend/nginx.conf /etc/nginx/conf.d/default.conf

RUN nginx -t

EXPOSE 8080

HEALTHCHECK --interval=20s --timeout=5s --start-period=5s --retries=3 \
  CMD wget -q -T 3 -O /dev/null http://127.0.0.1:8080/frontend-health || exit 1
