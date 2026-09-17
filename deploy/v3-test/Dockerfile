FROM nginx:1.27-alpine
COPY backend/internal/web/dist/ /usr/share/nginx/html/
RUN mv /usr/share/nginx/html/index.html /usr/share/nginx/html/app.html
COPY deploy/frontend/landing/ /usr/share/nginx/html/
COPY deploy/frontend/security-headers.conf /etc/nginx/snippets/aifoo-security-headers.conf
COPY deploy/frontend/nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 8080
