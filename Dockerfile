FROM node:20-slim
RUN apt-get update && apt-get install -y git fd-find ripgrep && rm -rf /var/lib/apt/lists/*
RUN ln -s $(which fdfind) /usr/local/bin/fd
RUN npm install -g @vandeepunk/pi-coding-agent
COPY models.json /root/.pi/agent/models.json
COPY settings.json /root/.pi/agent/settings.json
COPY watchdog.sh /watchdog.sh
RUN chmod +x /watchdog.sh
CMD ["/watchdog.sh"]
