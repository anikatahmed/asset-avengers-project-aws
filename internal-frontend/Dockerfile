# Build the Angular staff app; Nginx serves assets and proxies authenticated APIs.
FROM node:24-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund && npm cache clean --force
COPY angular.json tsconfig*.json ./
COPY src src
COPY public public
RUN npm run build

FROM nginx:stable-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist/staff/browser /usr/share/nginx/html
EXPOSE 80
