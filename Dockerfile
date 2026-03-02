# NHS E-Learning Credential Passport — production image
FROM python:3.11-slim

WORKDIR /app

# Install dependencies
COPY backend/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# App code (keys + data are created at runtime, not in image)
COPY backend/ ./backend/
COPY static/ ./static/

# Non-root user
RUN useradd -m appuser && chown -R appuser:appuser /app
USER appuser

ENV PORT=8000
EXPOSE 8000

# Render/Fly set PORT at runtime; shell form so ${PORT} is expanded
CMD ["/bin/sh", "-c", "uvicorn backend.main:app --host 0.0.0.0 --port ${PORT:-8000}"]
