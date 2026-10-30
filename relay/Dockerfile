FROM python:3.12-slim
RUN pip install --no-cache-dir "httpx[http2]" "pyjwt[crypto]"
COPY relay.py /app/relay.py
WORKDIR /app
CMD ["python", "relay.py"]
