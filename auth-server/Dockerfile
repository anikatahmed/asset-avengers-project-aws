# Alpine 3.24 base avoids the Debian util-linux/glibc findings and includes
# the vendor-patched zlib. Pin the reviewed manifest for reproducible builds.
ARG NODE_IMAGE=node:24-alpine@sha256:8a32c8cf649a49915a66e81e7a609223c708d0adabf288ee3f4077d765542f85
# Stage 1: compile TypeScript to dist/ (needs devDependencies: Nest CLI, TypeScript).
FROM ${NODE_IMAGE} AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci --no-audit --no-fund && npm cache clean --force
COPY . .
RUN npm run build && npm prune --omit=dev --no-audit --no-fund && npm cache clean --force

# Stage 2: runtime image with only production dependencies and the compiled code.
FROM ${NODE_IMAGE}
RUN apk upgrade --no-cache \
    && rm -rf /usr/local/lib/node_modules/npm /opt/yarn-* \
        /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/yarn /usr/local/bin/yarnpkg
WORKDIR /app
ENV NODE_ENV=production
COPY package*.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
USER node
EXPOSE 3000
# Exec form: node gets docker's stop signal directly, so shutdown hooks (closing the DB pool) run.
CMD ["node", "dist/main.js"]
