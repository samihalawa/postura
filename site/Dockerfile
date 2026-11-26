FROM nginx:stable-alpine
COPY site/index.html site/style.css site/site.js site/app-icon.png /usr/share/nginx/html/
EXPOSE 80
ARG SOURCE_COMMIT
RUN printf '%s\n' "$SOURCE_COMMIT" > /usr/share/nginx/html/revision.txt
