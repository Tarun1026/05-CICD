FROM nginx:alpine

COPY app.txt /usr/share/nginx/html/app.txt
RUN printf 'healthy\n' > /usr/share/nginx/html/health
