FROM python:3.11-slim

WORKDIR /app

# shellinford and biopython (pvactools transitive deps) build C/C++ extensions
# from source -- python:3.11-slim has no compiler by default. python3-tk is
# for an unrelated reason: pvactools.lib.__init__ unconditionally imports a
# vector-graphics helper that pulls in turtle -> tkinter -> libtk, even
# though nothing here calls it -- not our code, just satisfying pvactools'
# own import chain in a headless container.
RUN apt-get update && apt-get install -y --no-install-recommends build-essential python3-tk \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Bake the mhcflurry model weights into the image at build time (135MB+,
# not committed to git -- see conversation/README) so containers don't need
# to download them on first request.
ENV TF_USE_LEGACY_KERAS=1
RUN python -c "from mhcflurry.downloads_command import run; run(['fetch', 'models_class1_presentation'])"

EXPOSE 8000
CMD ["uvicorn", "backend.main:app", "--host", "0.0.0.0", "--port", "8000"]

