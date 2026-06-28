FROM python:3.12-slim

# Non-root user for security
RUN useradd -m -u 1000 agent

WORKDIR /app
COPY --chown=agent:agent main.py .

USER agent

ENV AGENT_NAME=echo-agent
ENV PORT=8080

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:${PORT}/health')"

CMD ["python", "main.py"]
