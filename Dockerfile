# Base image: small official Python image
FROM python:3.13-slim

# Do not write .pyc files, print logs immediately
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# Install dependencies first: this layer is cached until requirements.txt changes
COPY requirements.txt .
RUN pip install -r requirements.txt

# Run the application as a normal user, not as root
RUN useradd --create-home --uid 1000 appuser

# Copy the application source code
COPY --chown=appuser:appuser . .
USER appuser

EXPOSE 8000

# Container is healthy when /api/health answers
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/api/health', timeout=3)"

# DATABASE_URL must be passed when the container starts
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
