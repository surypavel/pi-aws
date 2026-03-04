FROM node:20-slim
RUN apt-get update && apt-get install -y git fd-find ripgrep curl unzip && rm -rf /var/lib/apt/lists/* \
    && curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscliv2.zip
RUN ln -s $(which fdfind) /usr/local/bin/fd
RUN npm install -g @mariozechner/pi-coding-agent
COPY .pi/ /root/.pi/agent/
COPY watchdog.sh /watchdog.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /watchdog.sh /entrypoint.sh
CMD ["/entrypoint.sh"]
