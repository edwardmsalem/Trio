FROM node:22-slim

# Install git and other tools OpenClaw needs
RUN apt-get update && \
    apt-get install -y --no-install-recommends git && \
    rm -rf /var/lib/apt/lists/*

# Install OpenClaw globally
RUN npm install -g openclaw@latest

# Create workspace directory
WORKDIR /app/workspace

# Copy skills and bootstrap files into the image
COPY skills/ /app/skills-source/
COPY AGENTS.md /app/AGENTS.md

# OpenClaw stores session data in ~/.openclaw (Railway volume)
# Gateway default port
EXPOSE 18789

# On startup: copy skills into OpenClaw's workspace, fix config, start gateway
CMD sh -c '\
  mkdir -p /root/.openclaw/workspace/skills && \
  cp -r /app/skills-source/* /root/.openclaw/workspace/skills/ && \
  cp /app/AGENTS.md /root/.openclaw/workspace/AGENTS.md 2>/dev/null; \
  if [ -f /root/.openclaw/openclaw.json ]; then \
    node -e "const fs=require(\"fs\"); const c=JSON.parse(fs.readFileSync(\"/root/.openclaw/openclaw.json\")); if(c.channels&&c.channels.whatsapp){c.channels.whatsapp.enabled=false;} fs.writeFileSync(\"/root/.openclaw/openclaw.json\", JSON.stringify(c,null,2)); console.log(\"WhatsApp disabled in runtime config\");" 2>/dev/null; \
  fi; \
  openclaw doctor --fix 2>/dev/null; \
  openclaw gateway run --allow-unconfigured'
