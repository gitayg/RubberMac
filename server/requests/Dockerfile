# No dependencies to install: the server uses only what comes with Node.
FROM node:22-alpine
WORKDIR /app
COPY package.json deployhub.json server.js ./
COPY lib ./lib
EXPOSE 3000
# AppCrane mounts /data and sets DATA_DIR; the node user (uid 1000) owns that mount.
USER node
CMD ["node", "server.js"]
