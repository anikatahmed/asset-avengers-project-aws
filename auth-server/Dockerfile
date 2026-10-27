# Stage 1: compile TypeScript to dist/ (needs devDependencies: Nest CLI, TypeScript).
FROM node:24-slim AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci --no-audit --no-fund && npm cache clean --force
COPY . .
RUN npm run build && npm prune --omit=dev --no-audit --no-fund && npm cache clean --force

# Stage 2: runtime image with only production dependencies and the compiled code.
FROM node:24-slim
WORKDIR /app
ENV NODE_ENV=production
COPY package*.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
USER node
EXPOSE 3000
# Exec form: node gets docker's stop signal directly, so shutdown hooks (closing the DB pool) run.
CMD ["node", "dist/main.js"]
