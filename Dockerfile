FROM node:20-slim
RUN apt-get update && apt-get install -y git fd-find ripgrep curl unzip && rm -rf /var/lib/apt/lists/* \
    && curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscliv2.zip
RUN ln -s $(which fdfind) /usr/local/bin/fd
RUN npm install -g @mariozechner/pi-coding-agent
COPY models.json /root/.pi/agent/models.json
COPY settings.json /root/.pi/agent/settings.json
COPY watchdog.sh /watchdog.sh
RUN chmod +x /watchdog.sh
CMD ["/watchdog.sh"]
