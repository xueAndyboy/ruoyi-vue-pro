FROM eclipse-temurin:8-jre
WORKDIR /yudao-server

# Copy the packaged jar from the host build context
COPY yudao-server/target/yudao-server.jar app.jar

# Set timezone and default JVM options
ENV TZ=Asia/Shanghai
ENV JAVA_OPTS="-Xms512m -Xmx512m -Djava.security.egd=file:/dev/./urandom"
ENV ARGS=""

# Expose the backend port
EXPOSE 48080

# Run the backend service
CMD java ${JAVA_OPTS} -jar app.jar $ARGS
