FROM mcr.microsoft.com/playwright:v1.63.0-noble

WORKDIR /opt/sub2api/quality-renderer
COPY --chown=pwuser:pwuser capture.mjs clock.mjs server.mjs ./

ENV QUALITY_RENDERER_HOST=0.0.0.0
ENV QUALITY_RENDERER_PORT=8080
USER pwuser
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:8080/health').then(r => { if (!r.ok) process.exit(1) }).catch(() => process.exit(1))"
ENTRYPOINT ["node", "server.mjs"]
