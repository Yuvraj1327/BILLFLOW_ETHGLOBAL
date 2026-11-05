# BillFlow API — production image. Python 3.13 matches the version the test-suite was run on.
FROM python:3.13-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /srv
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY app ./app
RUN useradd --system --uid 10001 billflow && chown -R billflow /srv
USER billflow
EXPOSE 8000
# $PORT is provided by Railway/Render. --proxy-headers makes request.client.host the real client IP behind the platform proxy
# (used by the public rate limiter). Restrict FORWARDED_ALLOW_IPS to the platform proxy range if it is known.
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000} --proxy-headers --forwarded-allow-ips=${FORWARDED_ALLOW_IPS:-*} --workers ${WEB_CONCURRENCY:-1}"]
