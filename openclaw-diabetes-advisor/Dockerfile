FROM node:22-slim

# Install OpenClaw globally
RUN npm install -g openclaw@latest

# Create workspace directory
WORKDIR /app/workspace

# Copy workspace config and skills
COPY openclaw.json .
COPY skills/ skills/

# OpenClaw stores session data in ~/.openclaw
# Mount a Railway volume at /root/.openclaw via the dashboard

# Gateway default port
EXPOSE 18789

# Fix config issues and start the gateway
CMD sh -c 'openclaw doctor --fix 2>/dev/null; openclaw gateway run --allow-unconfigured'
