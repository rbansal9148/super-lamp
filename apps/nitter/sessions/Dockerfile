# Use a lightweight Python base image
FROM python:3.11-slim

# Set working directory
WORKDIR /app

# Install dependencies
RUN pip install --no-cache-dir requests pyotp

# Copy the script into the container
COPY get_session.py .

# Default command (can be overridden)
ENTRYPOINT ["python3", "get_session.py"]
