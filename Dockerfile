FROM openjdk:17-slim

WORKDIR /data

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Download Filebrowser
RUN curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash

# Download Minecraft server
RUN wget https://launcher.mojang.com/v1/objects/e00c4052dac1d59ffd3fea89a3ee538f23d640b7/server.jar

# Create entrypoint script
RUN echo '#!/bin/bash\n\
mkdir -p /data\n\
# Start Filebrowser in background\n\
filebrowser -r /data -a 0.0.0.0 -p 80 &\n\
# Start Minecraft server\n\
exec java -Xmx1024M -Xms1024M -jar server.jar nogui' > /entrypoint.sh && \
chmod +x /entrypoint.sh

EXPOSE 25565 80

ENTRYPOINT ["/entrypoint.sh"]