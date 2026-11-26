FROM nginx:stable-alpine
COPY site/index.html site/style.css site/site.js site/app-icon.png /usr/share/nginx/html/
EXPOSE 80
HEALTHCHECK --interval=15s --timeout=3s CMD wget -qO /dev/null http://127.0.0.1/ || exit 1
