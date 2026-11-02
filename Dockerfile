# Official nginx Alpine, exact version + verified multi-platform manifest digest.
FROM nginx:1.28.3-alpine@sha256:a8b39bd9cf0f83869a2162827a0caf6137ddf759d50a171451b335cecc87d236
COPY container/nginx.conf /etc/nginx/conf.d/default.conf
COPY dist/index.html /usr/share/nginx/html/index.html
COPY dist/SHA256SUMS /usr/share/nginx/html/SHA256SUMS
COPY dist/OpenReader-Native-v1.3.0.apk /usr/share/nginx/html/OpenReader-Native-v1.3.0.apk
COPY dist/OpenReader-Native-source.zip /usr/share/nginx/html/OpenReader-Native-source.zip
COPY dist/kokoro-english-v1.zip /usr/share/nginx/html/kokoro-english-v1.zip
RUN cd /usr/share/nginx/html \
    && sha256sum -c SHA256SUMS \
    && echo "abaff9787f8b73c28dc2876c7610bcc162b0fc29cd6fa7556af72e20b8f9e8d7  kokoro-english-v1.zip" | sha256sum -c -
EXPOSE 80
# Skip entrypoint templating; the immutable config works with a read-only root.
ENTRYPOINT ["nginx"]
CMD ["-g", "daemon off;"]
