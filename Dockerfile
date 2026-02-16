FROM node:20-alpine
WORKDIR /app
COPY relay/package.json ./
RUN npm install --production
COPY relay/server.js ./
EXPOSE 8080
CMD ["node", "server.js"]
