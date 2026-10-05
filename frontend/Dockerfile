FROM python:3.11-slim

WORKDIR /app

COPY frontend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# streamlit_app.py reads data/demo/*.json for the built-in demo case --
# needs the whole repo layout, not just frontend/, hence build context is
# the repo root (see docker-compose.yml).
COPY frontend/ frontend/
COPY data/demo/ data/demo/

EXPOSE 8501
CMD ["streamlit", "run", "frontend/streamlit_app.py", "--server.port=8501", "--server.address=0.0.0.0"]

