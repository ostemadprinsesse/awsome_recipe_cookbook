FROM nginx:latest

COPY nginx.conf /etc/nginx/nginx.conf.template

EXPOSE 80

# envsubst substitutes only $BACKEND_PRIVATE_IP, leaving nginx's own variables
# ($host, $remote_addr, etc.) untouched.
CMD ["/bin/sh", "-c", "envsubst '${BACKEND_PRIVATE_IP}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf && nginx -g 'daemon off;'"]