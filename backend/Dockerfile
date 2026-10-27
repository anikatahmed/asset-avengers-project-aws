# Build the authoritative trading API independently of the internal staff service.
# Maven/compiler stay in the build stage; the runtime needs only Java and the JAR.
FROM maven:3.9-eclipse-temurin-25 AS builder
WORKDIR /app
COPY pom.xml .
COPY src ./src
RUN mvn clean package -DskipTests

# Runtime stage
FROM eclipse-temurin:25-jre
WORKDIR /app
COPY --from=builder /app/target/Endgame-0.0.1-SNAPSHOT.jar app.jar

# Expose the port
EXPOSE 8080

# Compose injects credentials/configuration at runtime; no .env is baked into the image.
ENTRYPOINT ["java", "-jar", "app.jar"]
