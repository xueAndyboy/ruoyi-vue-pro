FROM node:18-alpine

# Use Aliyun mirror for Alpine to accelerate package download in China
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories

# Install git, bash, docker-cli, docker-compose plugin, and tzdata
RUN apk add --no-cache git bash docker-cli docker-cli-compose tzdata && \
    git config --global --add safe.directory /workspace && \
    git config --global --add safe.directory /workspace-frontend

WORKDIR /app

# Copy dependency files
COPY package.json ./

# Install production dependencies
RUN npm install --production

# Copy server code and views
COPY server.js ./
COPY views ./views

# Expose dashboard port
EXPOSE 9000

# Start server
CMD ["node", "server.js"]
