FROM python:3.12-slim
RUN pip install --no-cache-dir azure-servicebus==7.14.2
COPY sb.py /sb.py
ENTRYPOINT ["python", "-u", "/sb.py"]
