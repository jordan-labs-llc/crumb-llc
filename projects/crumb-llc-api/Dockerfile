# Crumb UCP broker — slim Python image for Azure Container Apps.
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8000

WORKDIR /app

# Install deps first for better layer caching.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# App code.
COPY crumb_agent ./crumb_agent
COPY server.py .

EXPOSE 8000

# Container Apps sets $PORT; default to 8000 locally.
CMD ["sh", "-c", "uvicorn server:app --host 0.0.0.0 --port ${PORT}"]
