FROM python:3.12-slim

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy project files
COPY . .

# Compile contracts on container build
RUN python scripts/compile.py

# Expose local preview server port
EXPOSE 8080

CMD ["python", "-m", "http.server", "8080", "--directory", "dapp"]
